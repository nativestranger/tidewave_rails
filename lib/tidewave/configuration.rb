# frozen_string_literal: true

module Tidewave
  class Configuration
    attr_accessor :logger, :allow_remote_access, :preferred_orm, :dev, :client_url, :team, :logger_middleware,
                  :enabled, :shared_secret, :mode,
                  :async_job_log_exceptions, :async_job_log_runs,
                  :async_job_exceptions_logger, :async_job_runs_logger,
                  :async_job_exceptions_file, :async_job_exceptions_max_size, :async_job_exceptions_rotations,
                  :async_job_runs_file, :async_job_runs_max_size, :async_job_runs_rotations,
                  :async_job_logger_formatter, :async_job_logger_level

    def initialize
      @logger = nil
      @allow_remote_access = true
      @preferred_orm = :active_record
      @dev = false
      @client_url = "https://tidewave.ai"
      @team = {}
      @logger_middleware = nil
      
      # Ruby on Vibes production settings
      # Explicit opt-in via TIDEWAVE_ENABLED (independent of USE_MOUNTED_VIBES)
      # Default: ON in dev (convenient), OFF in production (secure)
      @enabled = if ENV['TIDEWAVE_ENABLED'] == 'false'
        false # Explicit disable overrides everything
      elsif ENV['TIDEWAVE_ENABLED'] == 'true'
        true # Explicit enable
      elsif Rails.env.development?
        true # Auto-enable in dev for convenience
      else
        false # Secure by default in production
      end
      
      @shared_secret = ENV['TIDEWAVE_SHARED_SECRET']
      @mode = ENV.fetch('TIDEWAVE_MODE', 'readonly').to_sym # :readonly, :full, :local
      
      # Async job logging - provides visibility for async-job adapter
      # Separate opt-in for exceptions vs runs (exceptions more important)
      @async_job_log_exceptions = false  # Set to true to log failures 
      @async_job_log_runs = false        # Set to true to log all executions
      
      # Custom logger instances (most flexible - provide your own Logger)
      @async_job_exceptions_logger = nil  # Custom logger for exceptions
      @async_job_runs_logger = nil        # Custom logger for runs
      
      # Production log file (configurable for Docker/volume deployments)
      # Default: Rails.root/log/#{Rails.env}.log
      # Override for persistent volumes: config.production_log_file = '/mnt/data/code/log/production.log'
      @production_log_file = nil  # Lazy default
      
      # Log file locations (lazy defaults - evaluated when first accessed)
      # Smart defaults for mounted volumes (detects USE_MOUNTED_VIBES)
      @async_job_exceptions_file = nil
      @async_job_runs_file = nil
      
      # Rotation settings (sensible defaults)
      @async_job_exceptions_max_size = 5.megabytes   # Exceptions stay small
      @async_job_exceptions_rotations = 2            # Keep 2 old exception logs
      @async_job_runs_max_size = 10.megabytes        # Runs can grow larger
      @async_job_runs_rotations = 1                  # Aggressive rotation for runs
      
      # Logger customization (used when creating default loggers)
      @async_job_logger_formatter = proc { |severity, datetime, progname, msg| "#{msg}\n" }
      @async_job_logger_level = Logger::INFO
    end
    
    # Lazy default for exceptions file (computed when first accessed)
    def async_job_exceptions_file
      @async_job_exceptions_file ||= default_log_path('async_job_exceptions.log')
    end
    
    # Allow manual override of exceptions file path
    def async_job_exceptions_file=(value)
      @async_job_exceptions_file = value
    end
    
    # Lazy default for runs file (computed when first accessed)
    def async_job_runs_file
      @async_job_runs_file ||= default_log_path('async_job_runs.log')
    end
    
    # Allow manual override of runs file path
    def async_job_runs_file=(value)
      @async_job_runs_file = value
    end
    
    # Lazy default for production log file (computed when first accessed)
    def production_log_file
      @production_log_file ||= default_log_path("#{Rails.env}.log")
    end
    
    # Allow manual override of production log file path
    def production_log_file=(value)
      @production_log_file = value
    end
    
    # Helper methods for mode detection (must be public for middleware)
    def production_mode?
      # Production mode = explicitly enabled outside of dev
      enabled && !Rails.env.development?
    end
    
    def local_dev?
      !production_mode? && Rails.env.development?
    end
    
    def readonly_mode?
      mode == :readonly
    end
    
    def full_mode?
      mode == :full
    end
    
    # MCP info for health endpoint (must be public for health controller)
    def mcp_info_for_health
      return nil unless enabled
      
      # Calculate tools available based on mode
      # Note: Actual count varies based on what's installed (async-job, SolidQueue)
      # This is the base count + commonly available tools
      tools_available = case mode
      when :readonly
        6  # get_models, get_logs, get_docs, get_source_location, get_async_job_logs, get_solid_queue_failures
      when :full
        8  # readonly tools + project_eval + execute_sql_query
      when :local
        8  # same as full in local dev
      else
        0
      end
      
      {
        enabled: true,
        mode: mode.to_s,
        tools_available: tools_available,
        version: Tidewave::VERSION,
        endpoint: '/tidewave/mcp'
      }
    end

    private
    
    # Default log path for async job logs
    # 
    # Simple default: Rails.root/log
    # Apps can override via:
    #   config.async_job_exceptions_file = '/custom/path.log'
    #
    # For Docker deployments with persistent volumes, the app should
    # configure paths to point to volume-mounted directories.
    def default_log_path(filename)
      Rails.root.join('log', filename).to_s
    end
  end
end
