# frozen_string_literal: true

require "rack/test"

RSpec.describe Tidewave::ExceptionsMiddleware do
  include Rack::Test::Methods

  describe "exception handling" do
    context "when exception is present" do
      let(:downstream_app) do
        lambda do |env|
          request = ActionDispatch::Request.new(env)
          exception = RuntimeError.new("Test error message")
          exception.set_backtrace([
            "/app/controllers/test_controller.rb:10:in `show'",
            "/app/lib/some_lib.rb:20:in `process'"
          ])
          # Use the correct header name that the middleware checks
          request.set_header("action_dispatch.exception", exception)

          [ 200, { "Content-Type" => "text/html" }, [ "<html><body><h1>Error Page</h1></body></html>" ] ]
        end
      end

      let(:middleware) { described_class.new(downstream_app) }
      let(:logger) { double("logger", info: nil, error: nil) }

      def app
        middleware
      end

      before do
        allow(Rails).to receive(:logger).and_return(logger)
      end

      it "logs exception info" do
        # Mock Rails.backtrace_cleaner to return the same backtrace
        backtrace_cleaner = double("backtrace_cleaner")
        allow(Rails).to receive(:backtrace_cleaner).and_return(backtrace_cleaner)
        allow(backtrace_cleaner).to receive(:clean).and_return([
          "/app/controllers/test_controller.rb:10:in `show'",
          "/app/lib/some_lib.rb:20:in `process'"
        ])

        get "/", {}, { "action_dispatch.request.path_parameters" => { "controller" => "test", "action" => "show" } }

        expect(last_response.status).to eq(200)
        # New implementation logs instead of embedding in response
        expect(logger).to have_received(:error).with(a_string_matching(/RuntimeError in TestController#show/))
        expect(logger).to have_received(:error).with(a_string_matching(/Test error message/))
      end

      it "handles exceptions without controller/action parameters" do
        backtrace_cleaner = double("backtrace_cleaner")
        allow(Rails).to receive(:backtrace_cleaner).and_return(backtrace_cleaner)
        allow(backtrace_cleaner).to receive(:clean).and_return([])

        get "/"

        expect(last_response.status).to eq(200)
        expect(logger).to have_received(:error).with(a_string_matching(/RuntimeError/))
        expect(logger).to have_received(:error).with(a_string_matching(/Unknown/))
      end

      it "handles exceptions without backtrace" do
        # Mock Rails.backtrace_cleaner to return empty array
        backtrace_cleaner = double("backtrace_cleaner")
        allow(Rails).to receive(:backtrace_cleaner).and_return(backtrace_cleaner)
        allow(backtrace_cleaner).to receive(:clean).and_return([])

        get "/"

        expect(last_response.status).to eq(200)
        expect(logger).to have_received(:error).with(a_string_matching(/RuntimeError/))
      end
    end

    context "when no exception is present" do
      let(:downstream_app) { ->(env) { [ 200, { "Content-Type" => "text/html" }, [ "<html><body><h1>Hello World</h1></body></html>" ] ] } }
      let(:middleware) { described_class.new(downstream_app) }

      def app
        middleware
      end

      it "does not modify response" do
        get "/"

        expect(last_response.status).to eq(200)
        expect(last_response.body).to eq("<html><body><h1>Hello World</h1></body></html>")
        expect(last_response.body).not_to include("data-tidewave-exception-info")
      end
    end
  end
end
