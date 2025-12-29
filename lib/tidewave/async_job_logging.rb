# frozen_string_literal: true

module Tidewave
  # AsyncJobLogging - Structured logging for async-job adapter
  # 
  # Provides visibility into async-job executions (exceptions + runs) via dedicated log files.
  # This fills the visibility gap for async-job (memory/Redis adapter) which has no UI or persistence,
  # unlike SolidQueue (Mission Control) and Sidekiq (Web UI).
  # 
  # Why two separate logs?
  # - Exception log: Small, scannable, critical errors only
  # - Runs log: All executions for debugging/performance analysis
  # 
  # Usage:
  #   config.tidewave.async_job_log_exceptions = true  # Log failures
  #   config.tidewave.async_job_log_runs = true        # Log all executions
  class AsyncJobLogging
    class << self
      def setup!(config)
        # Only enable if explicitly opted-in
        return unless config.async_job_log_exceptions || config.async_job_log_runs
        
        # Create or use provided loggers
        # Note: We don't check global adapter here because apps can use multiple adapters
        # (e.g. solid_queue as default, but specific jobs using async_job)
        # The adapter check happens per-job at runtime
        exceptions_logger = if config.async_job_log_exceptions
          config.async_job_exceptions_logger || create_logger(
            config.async_job_exceptions_file,
            config.async_job_exceptions_max_size,
            config.async_job_exceptions_rotations,
            config.async_job_logger_formatter,
            config.async_job_logger_level
          )
        end
        
        runs_logger = if config.async_job_log_runs
          config.async_job_runs_logger || create_logger(
            config.async_job_runs_file,
            config.async_job_runs_max_size,
            config.async_job_runs_rotations,
            config.async_job_logger_formatter,
            config.async_job_logger_level
          )
        end
        
        # Subscribe to ActiveJob instrumentation
        # Note: This fires for ALL jobs regardless of adapter, so we filter per-job
        ActiveSupport::Notifications.subscribe('perform.active_job') do |name, start, finish, id, payload|
          job = payload[:job]
          
          # Check THIS job's adapter (not global default)
          # Jobs can override with: self.queue_adapter = :async_job
          job_adapter_name = job.class.queue_adapter_name
          
          # Only track async-job adapter (SolidQueue/Sidekiq have their own dashboards)
          # Handle both string and symbol (Rails version differences)
          next unless ["async", "async_job", :async, :async_job].include?(job_adapter_name)
          
          if payload[:exception_object]
            # Job failed
            exception = payload[:exception_object]
            log_exception(exceptions_logger, id, job, exception) if exceptions_logger
            log_exception(runs_logger, id, job, exception) if runs_logger # Also in runs log
          else
            # Job succeeded
            log_success(runs_logger, id, job, start, finish) if runs_logger
          end
        end
        
        # Log activation
        global_adapter = Rails.application.config.active_job.queue_adapter
        if exceptions_logger && runs_logger
          Rails.logger.info "[Tidewave] async-job logging enabled (exceptions + runs) [global adapter: #{global_adapter}]"
        elsif exceptions_logger
          Rails.logger.info "[Tidewave] async-job logging enabled (exceptions only) [global adapter: #{global_adapter}]"
        elsif runs_logger
          Rails.logger.info "[Tidewave] async-job logging enabled (runs only) [global adapter: #{global_adapter}]"
        end
        Rails.logger.info "[Tidewave] Multiplex mode: Will track async-job adapter jobs even if default is #{global_adapter}"
      end
      
      private
      
      def create_logger(file_path, max_size, rotations, formatter, level)
        # Ensure directory exists and is writable
        dir = File.dirname(file_path)
        FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
        
        logger = Logger.new(file_path, rotations, max_size)
        logger.formatter = formatter
        logger.level = level
        logger
      rescue => e
        Rails.logger.error "[Tidewave] Failed to create async-job logger at #{file_path}: #{e.message}"
        nil
      end
      
      def log_exception(logger, id, job, exception)
        return unless logger
        
        logger.error <<~LOG
          [ASYNC_JOB_EXCEPTION] [#{id}] #{exception.class} in #{job.class.name}
          Message: #{exception.message}
          Job ID: #{job.job_id}
          Queue: #{job.queue_name}
          Arguments: #{job.arguments.inspect}
          Enqueued At: #{job.enqueued_at}
          Backtrace:
          #{exception.backtrace&.first(15)&.map { |line| "  #{line}" }&.join("\n")}
        LOG
      end
      
      def log_success(logger, id, job, start, finish)
        return unless logger
        
        duration = ((finish - start) * 1000).round(2)
        
        logger.info <<~LOG
          [ASYNC_JOB_SUCCESS] [#{id}] #{job.class.name}
          Job ID: #{job.job_id}
          Queue: #{job.queue_name}
          Duration: #{duration}ms
          Arguments: #{job.arguments.inspect}
          Enqueued At: #{job.enqueued_at}
        LOG
      end
    end
  end
end

