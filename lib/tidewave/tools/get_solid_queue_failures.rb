# frozen_string_literal: true

class Tidewave::Tools::GetSolidQueueFailures < Tidewave::Tools::Base
  tool_name "get_solid_queue_failures"
  description <<~DESCRIPTION
    Get failed SolidQueue background jobs with error details, arguments, and backtraces.

    Returns comprehensive failure information including:
    - Job class, queue, and priority
    - Exception class and error message
    - Full backtrace for debugging
    - Job arguments (serialized)
    - Enqueued and failed timestamps

    Note: Only available when SolidQueue is configured. For async-job failures,
    use get_async_job_logs tool instead.
  DESCRIPTION

  arguments do
    optional(:limit).filled(:integer).description("Maximum number of failures to return (default: 50, max: 500)")
    optional(:queue_name).filled(:string).description("Filter by queue name (e.g., 'default', 'mailers')")
    optional(:job_class).filled(:string).description("Filter by job class name (e.g., 'UserMailerJob')")
    optional(:since).filled(:string).description("Only show failures since timestamp. Supports: '15m', '1h', '6h', '1d', '1w' or ISO8601 timestamp (e.g. '2024-12-02T23:00:00')")
  end

  def call(limit: 50, queue_name: nil, job_class: nil, since: nil)
    return not_available_response unless solid_queue_available?

    limit = [ [ limit.to_i, 1 ].max, 500 ].min

    begin
      # Query failed jobs with their execution errors
      # Join to failed_executions table for error details
      failed_jobs = SolidQueue::Job
        .joins(:failed_execution)
        .includes(:failed_execution)
        .order("solid_queue_failed_executions.created_at DESC")
        .limit(limit)

      failed_jobs = failed_jobs.where(queue_name: queue_name) if queue_name.present?
      failed_jobs = failed_jobs.where(class_name: job_class) if job_class.present?

      if since.present?
        cutoff_time = parse_since(since)
        if cutoff_time
          failed_jobs = failed_jobs.where("solid_queue_failed_executions.created_at >= ?", cutoff_time)
        end
      end

      failures = failed_jobs.map do |job|
        failed_execution = job.failed_execution

        {
          type: "exception",
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

  def parse_since(since_param)
    case since_param
    when /^(\d+)m$/
      $1.to_i.minutes.ago
    when /^(\d+)h$/
      $1.to_i.hours.ago
    when /^(\d+)d$/
      $1.to_i.days.ago
    when /^(\d+)w$/
      $1.to_i.weeks.ago
    else
      # Parse timestamp - use Time.parse for consistent timezone handling
      Time.parse(since_param)
    end
  rescue ArgumentError => e
    Rails.logger.warn "[GetSolidQueueFailures] Invalid since parameter: #{since_param} - #{e.message}"
    nil
  end

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
    return "" unless arguments_hash.is_a?(Hash)

    # SolidQueue stores the FULL ActiveJob serialized hash in the arguments column
    # Structure: { "job_class" => "MyJob", "arguments" => [arg1, arg2, ...], ... }
    # We need to extract just the arguments array
    args = arguments_hash["arguments"] || arguments_hash[:arguments]

    # If no arguments key, this might be a different format - return empty
    return "" unless args.is_a?(Array)

    # Return empty string if no args (don't show "[]")
    return "" if args.empty?

    args.map { |arg| format_single_argument(arg) }.join(", ")
  rescue => e
    Rails.logger.warn "[Tidewave] Failed to format arguments: #{e.message}"
    ""
  end

  # Format a single argument for readability
  def format_single_argument(arg)
    case arg
    when String
      arg.length > 50 ? "#{arg[0..47]}..." : arg
    when Hash
      # GlobalID or serialized object
      if arg["_aj_globalid"]
        arg["_aj_globalid"]
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
