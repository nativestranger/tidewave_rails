# frozen_string_literal: true

require "logger"
require "fileutils"
require "tidewave/configuration"
require "tidewave/middleware"
require "tidewave/quiet_requests_middleware"
require "tidewave/exceptions_middleware"
require "tidewave/async_job_logging"

gem_tools_path = File.expand_path("tools/**/*.rb", __dir__)
Dir[gem_tools_path].each { |f| require f }

# Temporary monkey patching to address regression in FastMCP
if Dry::Schema::Macros::Hash.method_defined?(:original_call)
  Dry::Schema::Macros::Hash.class_eval do
    def call(*args, &block)
      if block
        # Use current context to track nested context if available
        context = MetadataContext.current
        if context
          context.with_nested(name) do
            original_call(*args, &block)
          end
        else
          original_call(*args, &block)
        end
      else
        original_call(*args)
      end
    end
  end
end

module Tidewave
  class Railtie < Rails::Railtie
    config.tidewave = Tidewave::Configuration.new()

    initializer "tidewave.setup" do |app|
      # Skip if not explicitly enabled
      unless app.config.tidewave.enabled
        Rails.logger.info "[Tidewave] Skipped: not enabled (set config.tidewave.enabled = true or USE_MOUNTED_VIBES=true)"
        next
      end

      # In local dev, no restrictions. In production, require explicit opt-in.
      unless app.config.enable_reloading || app.config.tidewave.production_mode?
        Rails.logger.warn "[Tidewave] Skipped: not in development and not in production mode"
        next
      end

      app.config.middleware.insert_after(
        ActionDispatch::Callbacks,
        Tidewave::Middleware,
        app.config.tidewave
      )
    end

    # Exception tracking: Captures backend exceptions for AI debugging
    # Frontend errors tracked by iframe bridge, backend errors tracked here
    # Makes exceptions queryable via get_logs tool
    initializer "tidewave.exceptions" do |app|
      next unless app.config.tidewave.enabled
      
      # Judo move: Just append to stack, middleware checks for exception internally
      # Works with any ShowExceptions implementation (ActionDispatch or ConciseErrors)
      # No need to detect which middleware is present
      app.config.middleware.use Tidewave::ExceptionsMiddleware
    end

    initializer "tidewave.logging" do |app|
      # Do not pollute user logs with tidewave requests.
      logger_middleware = app.config.tidewave.logger_middleware || Rails::Rack::Logger
      app.middleware.insert_before(logger_middleware, Tidewave::QuietRequestsMiddleware)
    end

    # AsyncJob logging: Provides visibility for async-job adapter (no UI/persistence)
    # Only activates when explicitly enabled via config
    initializer "tidewave.async_job_logging", after: :load_config_initializers do |app|
      next unless app.config.tidewave.enabled
      
      # Wait for ActiveJob to be fully configured
      ActiveSupport.on_load(:active_job) do
        Tidewave::AsyncJobLogging.setup!(app.config.tidewave)
      end
    end
  end
end
