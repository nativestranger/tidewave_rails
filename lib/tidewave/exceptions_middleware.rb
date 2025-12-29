# frozen_string_literal: true

# Ruby on Vibes Exception Tracking Middleware
#
# Captures and logs backend exceptions with rich context for AI debugging.
# Unlike the original Tidewave middleware (which embedded errors in HTML),
# this version:
#   - Logs exceptions with request_id, controller, params, user context
#   - Makes exceptions queryable via get_logs tool
#   - Doesn't modify response body (concise_errors handles frontend display)
#   - Works for both HTML and JSON responses
#
# Frontend errors are tracked by iframe bridge.
# Backend errors are tracked here and queryable via MCP.

class Tidewave::ExceptionsMiddleware
  def initialize(app)
    @app = app
    # Log that middleware is loaded (appears in app boot logs)
    Rails.logger.info "✅ [Boot] Tidewave::ExceptionsMiddleware loaded" if defined?(Rails.logger)
  end

  def call(env)
    request = ActionDispatch::Request.new(env)
    # CRITICAL: Use Rails' internal UUID (matches X-Vibes-Request-ID header)
    # This ensures backend exception logs correlate with frontend network captures
    request_id = request.uuid
    
    begin
      status, headers, body = @app.call(env)
      
      # Check BOTH env keys - different middleware use different keys
      exception = request.get_header("action_dispatch.exception") || 
                  request.get_header("action_dispatch.show_detailed_exceptions.exception")
      
      if exception
        log_exception(exception, request, request_id, status)
      end
      
      # Also check if concise_errors set an exception in env
      if env['concise_errors.exception']
        log_exception(env['concise_errors.exception'], request, request_id, status)
      end
      
      [ status, headers, body ]
    rescue => error
      # Catch exceptions at middleware level (before ShowExceptions/ConciseErrors)
      log_exception(error, request, request_id, 500)
      raise error # Re-raise so error page still displays
    end
  end

  private

  def log_exception(exception, request, request_id, status)
    # Build structured exception log for AI debugging
    backtrace = Rails.backtrace_cleaner.clean(exception.backtrace || [])
    params = safe_request_parameters(request)
    
    # Extract controller/action context
    controller_action = if params["controller"] && params["action"]
      "#{params['controller'].camelize}Controller##{params['action']}"
    else
      "Unknown"
    end
    
    # Log with structured format that get_logs can search
    log_message = <<~LOG.strip
      [EXCEPTION] [#{request_id}] #{exception.class.name} in #{controller_action}
      Message: #{exception.message}
      Status: #{status}
      Method: #{request.request_method}
      Path: #{request.path}
      Query: #{request.query_string.presence || 'none'}
      Backtrace:
      #{backtrace.first(10).map { |line| "  #{line}" }.join("\n")}
    LOG
    
    # Log at ERROR level so it's easily found
    Rails.logger.error(log_message)
    
    # Optional: Post to platform API for telemetry dashboard (P2 feature)
    # This would allow the platform to show "Your app has X errors" in UI
    post_to_platform_if_configured(exception, request, request_id, status)
  end
  
  def safe_request_parameters(request)
    request.parameters
  rescue ActionController::BadRequest, StandardError
    {}
  end
  
  def post_to_platform_if_configured(exception, request, request_id, status)
    # P2 Feature: Post exceptions to platform API for dashboard
    # Only if VIBES_API_TOKEN is set (deployed apps have this)
    return unless ENV['VIBES_API_TOKEN'].present?
    return unless ENV['USE_MOUNTED_VIBES'] == 'true'
    
    # Non-blocking: Queue a job to post exception data
    # This way exceptions don't slow down request processing
    begin
      # Future: VibesExceptionReportJob.perform_later({
      #   exception_class: exception.class.name,
      #   message: exception.message,
      #   request_id: request_id,
      #   status: status,
      #   path: request.path,
      #   timestamp: Time.current.iso8601
      # })
    rescue => e
      # Silently fail - logging is more important than reporting
      Rails.logger.debug "[Tidewave] Failed to queue exception report: #{e.message}"
    end
  end
end
