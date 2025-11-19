# frozen_string_literal: true

module Tidewave
  class Configuration
    attr_accessor :logger, :allow_remote_access, :preferred_orm, :dev, :client_url, :team, :logger_middleware,
                  :enabled, :shared_secret, :mode

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
    end
    
    # Helper methods for mode detection
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
    
    # MCP info for health endpoint (better encapsulation than middleware class method)
    def mcp_info_for_health
      return nil unless enabled
      
      # Calculate tools available based on mode
      tools_available = case mode
      when :readonly
        4  # get_models, get_logs, get_docs, get_source_location
      when :full
        6  # readonly tools + project_eval + execute_sql_query
      when :local
        6  # same as full in local dev
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
  end
end
