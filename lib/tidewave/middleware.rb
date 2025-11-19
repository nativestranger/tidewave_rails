# frozen_string_literal: true

require "open3"
require "ipaddr"
require "fast_mcp"
require "rack/request"
require "active_support/core_ext/class"
require "active_support/core_ext/object/blank"
require "json"
require "erb"
require_relative "streamable_http_transport"

class Tidewave::Middleware
  TIDEWAVE_ROUTE = "tidewave".freeze
  MCP_ROUTE = "mcp".freeze
  SHELL_ROUTE = "shell".freeze
  CONFIG_ROUTE = "config".freeze

  INVALID_IP = <<~TEXT.freeze
    For security reasons, Tidewave does not accept remote connections by default.

    If you really want to allow remote connections, set `config.tidewave.allow_remote_access = true`.
  TEXT

  def initialize(app, config)
    @config = config
    @allow_remote_access = config.allow_remote_access
    @client_url = config.client_url
    @team = config.team
    @project_name = Rails.application.class.module_parent.name

    # OPTIMIZATION: Only load FastMCP if enabled (saves ~20MB + 350ms boot when disabled)
    if config.enabled
      @app = FastMcp.rack_middleware(app,
        name: "tidewave",
        version: Tidewave::VERSION,
        path_prefix: "/" + TIDEWAVE_ROUTE + "/" + MCP_ROUTE,
        transport: Tidewave::StreamableHttpTransport,
        logger: config.logger || Logger.new(Rails.root.join("log", "tidewave.log")),
        # Rails runs the HostAuthorization in dev, so we skip this
        allowed_origins: [],
        # We validate this one in Tidewave::Middleware
        localhost_only: false
      ) do |server|
        server.filter_tools do |request, tools|
          # Apply mode-based security filtering
          filtered = apply_tool_security(tools, config.mode)
          
          # Original filesystem tool filtering
          if request.params["include_fs_tools"] != "true"
            filtered.reject { |tool| tool.tags.include?(:file_system_tool) }
          else
            filtered
          end
        end

        server.register_tools(*Tidewave::Tools::Base.descendants)
      end
    else
      # Pass through without MCP middleware (no overhead)
      @app = app
    end
  end

  def call(env)
    request = Rack::Request.new(env)
    path = request.path.split("/").reject(&:empty?)

    if path[0] == TIDEWAVE_ROUTE
      # Extract and track request ID for correlation
      request_id = request.get_header('HTTP_X_REQUEST_ID') || SecureRandom.uuid
      Thread.current[:tidewave_request_id] = request_id

      # All routes require authentication
      return unauthorized unless authenticated?(request)
      return forbidden(INVALID_IP) unless valid_client_ip?(request)

      # The MCP routes are handled downstream by FastMCP
      case [ request.request_method, path ]
      when [ "GET", [ TIDEWAVE_ROUTE, CONFIG_ROUTE ] ]
        return config_endpoint(request)
      when [ "POST", [ TIDEWAVE_ROUTE, SHELL_ROUTE ] ]
        # Shell endpoint: programmatic command execution (full mode only)
        # Benefits over fly ssh: bearer auth, app context, audit trail, agent integration
        unless @config.full_mode?
          return forbidden("Shell endpoint requires full mode (set TIDEWAVE_MODE=full)")
        end
        return shell(request)
      # Removed: home() - HTML UI not needed for MCP-only usage
      # Removed: health() - Redundant with /vibes/api/health
      end
    end

    status, headers, body = @app.call(env)

    # Remove X-Frame-Options headers for non-Tidewave routes to allow embedding.
    # CSP headers are configured in the CSP application environment.
    headers.delete("X-Frame-Options")

    [ status, headers, body ]
  end

  private

  # Authentication: require bearer token in production mode
  def authenticated?(request)
    # In local dev, skip auth for convenience
    return true if @config.local_dev?
    
    # In production mode, require shared secret via bearer token
    return false unless @config.shared_secret.present?
    
    auth_header = request.get_header('HTTP_AUTHORIZATION')
    return false unless auth_header
    
    token = auth_header.to_s.sub(/^Bearer /, '')
    ActiveSupport::SecurityUtils.secure_compare(token, @config.shared_secret)
  end
  
  def unauthorized
    Rails.logger.warn "[Tidewave] Unauthorized request"
    response = {
      error: "Unauthorized",
      hint: "Set TIDEWAVE_SHARED_SECRET env var and pass as Bearer token",
      request_id: Thread.current[:tidewave_request_id]
    }
    [ 401, { "Content-Type" => "application/json" }, [ JSON.generate(response) ] ]
  end
  
  # Tool security: filter based on mode
  def apply_tool_security(tools, mode)
    case mode
    when :readonly
      # Safe read-only introspection tools only
      safe_tools = %w[get_models get_logs get_docs get_source_location]
      tools.select { |tool| safe_tools.include?(tool.tool_name) }
    when :full
      # All registered tools (shell already removed from routes)
      tools
    when :local
      # Local dev: allow everything
      tools
    else
      # Unknown mode: no tools (paranoid default)
      Rails.logger.warn "[Tidewave] Unknown mode: #{mode}, no tools allowed"
      []
    end
  end

  # Health check removed - use /vibes/api/health instead (no redundancy)
  # MCP info available via mcp_info() helper for inclusion in main health endpoint

  def config_endpoint(request)
    data = config_data.merge(
      request_id: Thread.current[:tidewave_request_id]
    )
    [ 200, { "Content-Type" => "application/json" }, [ JSON.generate(data) ] ]
  end

  def config_data
    {
      "project_name" => @project_name,
      "framework_type" => "rails",
      "tidewave_version" => Tidewave::VERSION,
      "team" => @team,
      "mode" => @config.mode.to_s
    }
  end
  
  # Removed: mcp_info moved to Configuration class for better encapsulation

  def forbidden(message)
    Rails.logger.warn(message)
    response = {
      error: "Forbidden",
      message: message,
      request_id: Thread.current[:tidewave_request_id]
    }
    [ 403, { "Content-Type" => "application/json" }, [ JSON.generate(response) ] ]
  end
  
  # Shell endpoint: Programmatic command execution
  # Safer than fly ssh: runs as rails user, bearer auth, audit trail, rate limiting
  # Same risk level as project_eval (both allow system access)
  def shell(request)
    body = request.body.read
    return [ 400, { "Content-Type" => "text/plain" }, [ "Command body is required" ] ] if body.blank?

    begin
      parsed_body = JSON.parse(body)
      cmd = parsed_body["command"]
      return [ 400, { "Content-Type" => "text/plain" }, [ "Command field is required" ] ] if cmd.blank?
    rescue JSON::ParserError
      return [ 400, { "Content-Type" => "text/plain" }, [ "Invalid JSON in request body" ] ]
    end
    
    # SECURITY: Audit log every shell command (track who runs what)
    request_id = Thread.current[:tidewave_request_id]
    Rails.logger.warn "[Tidewave::Shell] [#{request_id}] Executing: #{cmd.inspect}"
    
    # SAFETY: Blocklist obvious disasters (prevent fat-finger mistakes)
    cmd_string = cmd.join(' ')
    dangerous_patterns = [
      /rm\s+-rf\s+\/\s*$/,           # rm -rf /
      /rm\s+-rf\s+\/\*\s*$/,         # rm -rf /*
      /dd\s+if=.*of=\/dev\/sd/,       # dd to disk
      /:\(\)\{\s*:\|\:&\s*\};:/      # fork bomb
    ]
    
    if dangerous_patterns.any? { |pattern| cmd_string.match?(pattern) }
      Rails.logger.error "[Tidewave::Shell] [#{request_id}] BLOCKED dangerous command: #{cmd_string}"
      return [ 403, { "Content-Type" => "text/plain" }, [ "Command blocked by safety filter" ] ]
    end

    # Execute command with streaming output (useful for long-running tasks)
    response = Rack::Response.new
    response.status = 200
    response.headers["Content-Type"] = "text/plain"
    response.headers["X-Request-ID"] = request_id if request_id

    response.finish do |res|
      begin
        # SAFETY: Limit total output to 100MB (prevent memory exhaustion)
        max_output_bytes = 100 * 1024 * 1024  # 100MB
        total_bytes_written = 0
        
        Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
          stdin.close

          # Merge stdout and stderr streams
          ios = [ stdout, stderr ]

          until ios.empty?
            ready = IO.select(ios, nil, nil, 0.1)
            next unless ready

            ready[0].each do |io|
              begin
                data = io.read_nonblock(4096)
                if data
                  # Check output size limit
                  if total_bytes_written + data.bytesize > max_output_bytes
                    Rails.logger.warn "[Tidewave::Shell] [#{request_id}] Output limit reached (100MB), truncating"
                    # Write truncation message
                    truncated_msg = "\n\n[Output truncated at 100MB limit]"
                    chunk = [ 0, truncated_msg.bytesize ].pack("CN") + truncated_msg
                    res.write(chunk)
                    # Kill the process
                    Process.kill('TERM', wait_thr.pid) rescue nil
                    ios.clear
                    break
                  end
                  
                  # Write binary chunk: type (0 for data) + 4-byte length + data
                  chunk = [ 0, data.bytesize ].pack("CN") + data
                  res.write(chunk)
                  total_bytes_written += data.bytesize
                end
              rescue IO::WaitReadable
                # No data available right now
              rescue EOFError
                # Stream ended
                ios.delete(io)
              end
            end
          end

          # Wait for process to complete and get exit status
          exit_status = wait_thr.value.exitstatus
          status_json = JSON.generate({ status: exit_status })
          # Write binary chunk: type (1 for status) + 4-byte length + JSON data
          chunk = [ 1, status_json.bytesize ].pack("CN") + status_json
          res.write(chunk)
          
          Rails.logger.info "[Tidewave::Shell] [#{request_id}] Exit status: #{exit_status}"
        end
      rescue => e
        Rails.logger.error "[Tidewave::Shell] [#{request_id}] Error: #{e.message}"
        error_json = JSON.generate({ status: 213, error: e.message })
        chunk = [ 1, error_json.bytesize ].pack("CN") + error_json
        res.write(chunk)
      end
    end
  end

  def valid_client_ip?(request)
    return true if @allow_remote_access

    ip = request.ip
    return false unless ip

    addr = IPAddr.new(ip)

    addr.loopback? ||
    addr == IPAddr.new("127.0.0.1") ||
    addr == IPAddr.new("::1") ||
    addr == IPAddr.new("::ffff:127.0.0.1")  # IPv4-mapped IPv6
  end
end
