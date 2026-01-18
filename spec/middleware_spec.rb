# frozen_string_literal: true

require "rack/test"

RSpec.describe Tidewave::Middleware do
  include Rack::Test::Methods

  let(:downstream_app) { ->(env) { [ 200, {}, [ "Downstream App" ] ] } }
  let(:config) { Tidewave::Configuration.new }
  let(:middleware) { described_class.new(downstream_app, config) }

  def app
    middleware
  end

  # Stub local_dev? to bypass authentication in tests
  before do
    allow(config).to receive(:local_dev?).and_return(true)
  end

  describe "routing" do
    context "when accessing non-tidewave routes" do
      it "passes through to downstream app" do
        get "/other-route"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to eq("Downstream App")
      end

      it "passes through root route" do
        get "/"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to eq("Downstream App")
      end
    end
  end

  describe "header removal" do
    let(:downstream_app_with_headers) do
      ->(env) { [ 200, { "X-Frame-Options" => "DENY" }, [ "App with headers" ] ] }
    end

    def app
      described_class.new(downstream_app_with_headers, config)
    end

    it "removes X-Frame-Options headers from all responses" do
      get "/some-route"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["X-Frame-Options"]).to be_nil
      expect(last_response.body).to eq("App with headers")
    end

    it "removes headers from tidewave routes as well" do
      get "/tidewave/some-sub-route"
      expect(last_response.headers["X-Frame-Options"]).to be_nil
    end
  end

  describe "IP validation" do
    context "when remote access is allowed" do
      before do
        config.allow_remote_access = true
      end

      it "allows any IP address" do
        get "/tidewave", {}, { "REMOTE_ADDR" => "192.168.1.100" }
        expect(last_response.status).to eq(200)
      end

      it "allows localhost" do
        get "/tidewave", {}, { "REMOTE_ADDR" => "127.0.0.1" }
        expect(last_response.status).to eq(200)
      end
    end

    context "when remote access is not allowed" do
      before do
        config.allow_remote_access = false
      end

      it "allows localhost" do
        get "/tidewave", {}, { "REMOTE_ADDR" => "127.0.0.1" }
        expect(last_response.status).to eq(200)
      end

      it "rejects remote IP addresses" do
        get "/tidewave", {}, { "REMOTE_ADDR" => "192.168.1.100" }
        expect(last_response.status).to eq(403)
        # New implementation returns JSON format
        expect(last_response.headers["Content-Type"]).to eq("application/json")
        body = JSON.parse(last_response.body)
        expect(body["error"]).to eq("Forbidden")
        expect(body["message"]).to include("For security reasons, Tidewave does not accept remote connections by default")
        expect(body["message"]).to include("config.tidewave.allow_remote_access = true")
      end
    end
  end

  describe "MCP endpoint" do
    context "with allowed access" do
      before do
        config.allow_remote_access = true
      end

      it "handles GET requests to MCP endpoint" do
        # FastMCP middleware handles this route
        get "/tidewave/mcp"
        # FastMCP may return 200 with default response or handle differently
        expect(last_response.status).to eq(200)
      end

      it "handles POST requests to MCP endpoint" do
        # Send a valid JSON-RPC 2.0 ping request
        request_body = {
          jsonrpc: "2.0",
          method: "ping",
          id: 1
        }

        post "/tidewave/mcp", JSON.generate(request_body), { "CONTENT_TYPE" => "application/json" }
        expect(last_response.status).to eq(200)
        # FastMCP handles response format
        # Just verify it doesn't error
      end
    end

    context "with IP restrictions" do
      before do
        config.allow_remote_access = false
      end

      it "blocks GET requests for unauthorized IPs" do
        get "/tidewave/mcp", {}, { "REMOTE_ADDR" => "192.168.1.100" }
        expect(last_response.status).to eq(403)
      end

      it "blocks POST requests for unauthorized IPs" do
        post "/tidewave/mcp", JSON.generate({ jsonrpc: "2.0", method: "ping", id: 1 }), { "REMOTE_ADDR" => "192.168.1.100" }
        expect(last_response.status).to eq(403)
      end
    end
  end

  describe "/tidewave" do
    # Note: home page route was removed in current implementation
    # FastMCP middleware handles /tidewave/mcp, everything else passes through
    it "passes through to FastMCP middleware" do
      config.team = { id: "dashbit" }
      get "/tidewave"
      expect(last_response.status).to eq(200)
      # Should not get downstream app since FastMCP may handle with default response
    end
  end

  describe "/tidewave/config" do
    it "returns JSON configuration" do
      config.team = { id: "dashbit" }
      get "/tidewave/config"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to eq("application/json")

      parsed_config = JSON.parse(last_response.body)
      expect(parsed_config["framework_type"]).to eq("rails")
      expect(parsed_config["tidewave_version"]).to eq(Tidewave::VERSION)
      expect(parsed_config["team"]).to eq({ "id" => "dashbit" })
      expect(parsed_config).to have_key("project_name")
    end
  end

  describe "/tidewave/shell" do
    # Shell endpoint requires full mode
    before do
      allow(config).to receive(:full_mode?).and_return(true)
    end

    def parse_binary_response(body)
      chunks = []
      offset = 0

      while offset < body.bytesize
        type = body.getbyte(offset)
        length = body[offset + 1, 4].unpack1("N")
        data = body[offset + 5, length]
        chunks << { type: type, data: data }
        offset += 5 + length
      end

      chunks
    end

    it "executes simple command and returns output with status" do
      body = { command: ["sh", "-c", "echo 'hello world'"] }
      post "/tidewave/shell", JSON.generate(body)
      expect(last_response.status).to eq(200)

      chunks = parse_binary_response(last_response.body)
      expect(chunks.length).to eq(2)

      # First chunk should be stdout data
      expect(chunks[0][:type]).to eq(0)
      expect(chunks[0][:data]).to eq("hello world\n")

      # Second chunk should be status
      expect(chunks[1][:type]).to eq(1)
      status_data = JSON.parse(chunks[1][:data])
      expect(status_data["status"]).to eq(0)
    end

    it "handles command with non-zero exit status" do
      body = { command: ["sh", "-c", "exit 42"] }
      post "/tidewave/shell", JSON.generate(body)
      expect(last_response.status).to eq(200)

      chunks = parse_binary_response(last_response.body)
      expect(chunks.length).to eq(1)

      # Should only have status chunk
      expect(chunks[0][:type]).to eq(1)
      status_data = JSON.parse(chunks[0][:data])
      expect(status_data["status"]).to eq(42)
    end

    it "handles multiline commands" do
      body = {
        command: ["sh", "-c", "echo 'line 1'\necho 'line 2'"]
      }
      post "/tidewave/shell", JSON.generate(body)
      expect(last_response.status).to eq(200)

      chunks = parse_binary_response(last_response.body)

      # The shell command outputs both lines together
      expect(chunks.length).to eq(2)

      # First chunk should be stdout data with both lines
      expect(chunks[0][:type]).to eq(0)
      expect(chunks[0][:data]).to eq("line 1\nline 2\n")

      # Second chunk should be status
      expect(chunks[1][:type]).to eq(1)
      status_data = JSON.parse(chunks[1][:data])
      expect(status_data["status"]).to eq(0)
    end

    it "returns 400 for empty command body" do
      post "/tidewave/shell", ""
      expect(last_response.status).to eq(400)
      expect(last_response.body).to include("Command body is required")
    end

    it "returns 400 for invalid JSON" do
      post "/tidewave/shell", "not json"
      expect(last_response.status).to eq(400)
      expect(last_response.body).to include("Invalid JSON in request body")
    end

    it "returns 400 for missing command field" do
      body = { other_field: "value" }
      post "/tidewave/shell", JSON.generate(body)
      expect(last_response.status).to eq(400)
      expect(last_response.body).to include("Command field is required")
    end
  end

  describe "authentication" do
    before do
      # Disable local dev mode to test actual auth
      allow(config).to receive(:local_dev?).and_return(false)
      # Set a shared secret
      allow(config).to receive(:shared_secret).and_return("test-secret-123")
      # Allow remote access so IP check doesn't interfere
      config.allow_remote_access = true
    end

    context "with correct bearer token" do
      it "allows access to /tidewave/config" do
        header "Authorization", "Bearer test-secret-123"
        get "/tidewave/config"
        expect(last_response.status).to eq(200)
        expect(last_response.headers["Content-Type"]).to eq("application/json")
      end

      it "allows access to /tidewave/mcp" do
        header "Authorization", "Bearer test-secret-123"
        get "/tidewave/mcp"
        expect(last_response.status).to eq(200)
      end
    end

    context "without bearer token" do
      it "returns 401 for /tidewave/config" do
        get "/tidewave/config"
        expect(last_response.status).to eq(401)
        expect(last_response.headers["Content-Type"]).to eq("application/json")
        
        body = JSON.parse(last_response.body)
        expect(body["error"]).to eq("Unauthorized")
        expect(body["hint"]).to include("TIDEWAVE_SHARED_SECRET")
      end

      it "returns 401 for /tidewave/mcp" do
        get "/tidewave/mcp"
        expect(last_response.status).to eq(401)
      end
    end

    context "with incorrect bearer token" do
      it "returns 401 for /tidewave/config" do
        header "Authorization", "Bearer wrong-secret"
        get "/tidewave/config"
        expect(last_response.status).to eq(401)
        
        body = JSON.parse(last_response.body)
        expect(body["error"]).to eq("Unauthorized")
      end

      it "returns 401 for /tidewave/mcp" do
        header "Authorization", "Bearer wrong-secret"
        get "/tidewave/mcp"
        expect(last_response.status).to eq(401)
      end
    end

    context "with malformed authorization header" do
      it "returns 401 when missing 'Bearer ' prefix" do
        header "Authorization", "test-secret-123"
        get "/tidewave/config"
        expect(last_response.status).to eq(401)
      end

      it "returns 401 for empty authorization header" do
        header "Authorization", ""
        get "/tidewave/config"
        expect(last_response.status).to eq(401)
      end
    end

    context "when no shared_secret is configured" do
      before do
        allow(config).to receive(:shared_secret).and_return(nil)
      end

      it "returns 401 even with bearer token" do
        header "Authorization", "Bearer test-secret-123"
        get "/tidewave/config"
        expect(last_response.status).to eq(401)
      end
    end

    context "in local dev mode" do
      before do
        allow(config).to receive(:local_dev?).and_return(true)
      end

      it "bypasses auth check and allows access without token" do
        get "/tidewave/config"
        expect(last_response.status).to eq(200)
      end
    end
  end

  describe "edge cases" do
    it "handles trailing slashes" do
      get "/tidewave/"
      expect(last_response.status).to eq(200)
      # /tidewave/ gets normalized to /tidewave and passes through FastMCP to downstream
      # This is acceptable behavior as trailing slash is handled consistently
    end

    it "handles case sensitivity" do
      get "/TIDEWAVE"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("Downstream App")
    end
  end
end
