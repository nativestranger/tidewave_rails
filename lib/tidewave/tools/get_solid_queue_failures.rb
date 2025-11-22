# frozen_string_literal: true

module Tidewave
  module Tools
    # Get failed SolidQueue jobs with comprehensive error details
    # 
    # SolidQueue stores failures in the database (unlike async-job which uses logs)
    # This provides a unified interface to query failed jobs alongside Web and Async errors
    #
    # Usage:
    #   tool = GetSolidQueueFailures.new
    #   tool.call(limit: 50, queue_name: 'default')
    #
    class GetSolidQueueFailures < Base
      tool_name "get_solid_queue_failures"
      description "Get failed SolidQueue background jobs with error details, arguments, and backtraces"
      
      argument :limit, 
        type: "number",
        description: "Maximum number of failures to return (default: 50, max: 500)",
        default: 50
      
      argument :queue_name,
        type: "string", 
        description: "Filter by queue name (optional, e.g., 'default', 'mailers')",
        required: false
      
      argument :job_class,
        type: "string",
        description: "Filter by job class name (optional, e.g., 'UserMailerJob')",
        required: false

      def call(limit: 50, queue_name: nil, job_class: nil)
        # Validate SolidQueue availability
        return not_available_response unless solid_queue_available?
        
        # Sanitize limit
        limit = [[limit.to_i, 1].max, 500].min
        
        begin
          # Query failed jobs with their execution errors
          # Join to failed_executions table for error details
          failed_jobs = SolidQueue::Job
            .joins(:failed_execution)
            .includes(:failed_execution)
            .order('solid_queue_failed_executions.created_at DESC')
            .limit(limit)
          
          # Apply filters if provided
          failed_jobs = failed_jobs.where(queue_name: queue_name) if queue_name.present?
          failed_jobs = failed_jobs.where(class_name: job_class) if job_class.present?
          
          # Transform to unified format (matches async-job format)
          failures = failed_jobs.map do |job|
            failed_execution = job.failed_execution
            
            {
              type: 'exception',
              job_class: job.class_name,
              queue: job.queue_name,
              exception_class: failed_execution.exception_class,
              message: failed_execution.message,
              backtrace: Array(failed_execution.backtrace),
              arguments: format_arguments(job.arguments),
              job_id: job.active_job_id,
              failed_at: failed_execution.created_at.iso8601,
              enqueued_at: job.created_at.iso8601,
              duration: calculate_duration(job.created_at, failed_execution.created_at),
              # Additional SolidQueue-specific metadata
              solid_queue_job_id: job.id,
              priority: job.priority,
              scheduled_at: job.scheduled_at&.iso8601
            }
          end
          
          # Return structured response
          {
            failures: failures,
            count: failures.size,
            total_failed: total_failed_count,
            filters: {
              queue_name: queue_name,
              job_class: job_class,
              limit: limit
            }.compact
          }.to_json
          
        rescue => e
          error_response(e)
        end
      end
      
      private
      
      # Check if SolidQueue is available and configured
      def solid_queue_available?
        defined?(SolidQueue) && 
          defined?(SolidQueue::Job) && 
          SolidQueue::Job.table_exists? &&
          SolidQueue::FailedExecution.table_exists?
      rescue => e
        Rails.logger.error "[Tidewave] SolidQueue availability check failed: #{e.message}"
        false
      end
      
      # Get total count of failed jobs (for metadata)
      def total_failed_count
        SolidQueue::FailedExecution.count
      rescue
        0
      end
      
      # Format job arguments for display
      # Matches async-job format: "arg1, arg2, arg3"
      def format_arguments(arguments_hash)
        return '' unless arguments_hash.is_a?(Hash)
        
        # ActiveJob serializes as: { "arguments" => [arg1, arg2, ...] }
        args = arguments_hash['arguments'] || arguments_hash[:arguments] || []
        
        args.map { |arg| format_single_argument(arg) }.join(', ')
      rescue => e
        Rails.logger.warn "[Tidewave] Failed to format arguments: #{e.message}"
        arguments_hash.to_s
      end
      
      # Format a single argument for readability
      def format_single_argument(arg)
        case arg
        when String
          arg.length > 50 ? "#{arg[0..47]}..." : arg
        when Hash
          # GlobalID or serialized object
          if arg['_aj_globalid']
            arg['_aj_globalid']
          else
            arg.inspect
          end
        when Array
          "[#{arg.size} items]"
        else
          arg.inspect
        end
      end
      
      # Calculate duration between enqueue and failure
      def calculate_duration(enqueued_at, failed_at)
        return nil unless enqueued_at && failed_at
        
        duration_seconds = (failed_at - enqueued_at).to_f
        
        if duration_seconds < 1
          "#{(duration_seconds * 1000).round}ms"
        elsif duration_seconds < 60
          "#{duration_seconds.round(1)}s"
        else
          minutes = (duration_seconds / 60).floor
          seconds = (duration_seconds % 60).round
          "#{minutes}m #{seconds}s"
        end
      rescue
        nil
      end
      
      # Response when SolidQueue is not available
      def not_available_response
        {
          failures: [],
          count: 0,
          message: "SolidQueue not available. Ensure SolidQueue is installed and configured.",
          available: false
        }.to_json
      end
      
      # Error response with details
      def error_response(exception)
        Rails.logger.error "[Tidewave] Failed to fetch SolidQueue failures: #{exception.message}"
        Rails.logger.error exception.backtrace.first(5).join("\n")
        
        {
          failures: [],
          count: 0,
          error: exception.message,
          error_class: exception.class.name
        }.to_json
      end
    end
  end
end

