# frozen_string_literal: true

require "logger"
require "fileutils"
require "tidewave/configuration"
require "tidewave/middleware"
require "tidewave/quiet_requests_middleware"
require "tidewave/exceptions_middleware"

gem_tools_path = File.expand_path("tools/**/*.rb", __dir__)
Dir[gem_tools_path].each { |f| require f }

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
      
      # Insert after ShowExceptions (or ConciseErrors::ShowExceptions if swapped)
      # ConciseErrors gem swaps ActionDispatch::ShowExceptions, so check for both
      show_exceptions_class = if defined?(ConciseErrors::ShowExceptions) && 
                                 app.config.middleware.include?(ConciseErrors::ShowExceptions)
        ConciseErrors::ShowExceptions
      else
        ActionDispatch::ShowExceptions
      end
      
      app.config.middleware.insert_after(
        show_exceptions_class,
        Tidewave::ExceptionsMiddleware
      )
    end

    initializer "tidewave.logging" do |app|
      # Do not pollute user logs with tidewave requests.
      logger_middleware = app.config.tidewave.logger_middleware || Rails::Rack::Logger
      app.middleware.insert_before(logger_middleware, Tidewave::QuietRequestsMiddleware)
    end
  end
end
