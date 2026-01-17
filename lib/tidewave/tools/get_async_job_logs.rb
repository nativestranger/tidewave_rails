# frozen_string_literal: true

# Only register this tool if async-job adapter is present
# This keeps tidewave generic and doesn't force async-job dependency
begin
  require "async/job"
rescue LoadError
  # async-job not available
end

if defined?(Async::Job)
  class Tidewave::Tools::GetAsyncJobLogs < Tidewave::Tools::Base
  tool_name "get_async_job_logs"
  description <<~DESCRIPTION
    Returns structured async-job execution logs (exceptions and/or runs).

    Only available when async-job adapter is configured. Shows:
    - Job class, queue, duration
    - Arguments and enqueued timestamps
    - Full backtraces for failures
    - Success/failure status

    Can fetch from two separate log sources:
    - exceptions: Failed jobs only (async_job_exceptions.log)
    - runs: All job executions (async_job_runs.log) - if enabled

    Note: This tool tracks async-job adapter only. For SolidQueue jobs,
    use database queries against solid_queue tables.
  DESCRIPTION

  arguments do
    required(:tail).filled(:integer).description("Number of job executions to return (default: 100)")
    optional(:grep).filled(:string).description("Filter logs by pattern (job class, error message, etc.)")
    optional(:source).filled(:string).description("Log source: 'exceptions' (default) or 'runs'")
    optional(:since).filled(:string).description("Only show jobs since timestamp. Supports: '15m', '1h', '6h', '1d', '1w' or ISO8601 timestamp (e.g. '2024-12-02T23:00:00')")
  end

  def call(tail: 100, grep: nil, source: "exceptions", since: nil)
    log_file = if source == "runs"
      get_runs_log_file
    else
      get_exceptions_log_file
    end

    unless File.exist?(log_file)
      return {
        jobs: [],
        count: 0,
        source: source,
        message: "#{source} log not found at #{log_file}. #{not_found_help(source)}"
      }.to_json
    end

    cutoff_time = parse_since(since) if since
    jobs = parse_async_job_logs(log_file, tail * 2, grep)

    if cutoff_time
      jobs = jobs.select { |job| job_after_cutoff?(job, cutoff_time) }
    end

    jobs = jobs.first(tail)

    {
      jobs: jobs,
      count: jobs.size,
      source: source,
      total_in_log: File.size(log_file)
    }.to_json
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
    Rails.logger.warn "[GetAsyncJobLogs] Invalid since parameter: #{since_param} - #{e.message}"
    nil
  end

  def job_after_cutoff?(job, cutoff_time)
    # Try to parse enqueued_at timestamp from job
    return true unless job[:enqueued_at]

    begin
      job_time = Time.parse(job[:enqueued_at])
      job_time >= cutoff_time
    rescue ArgumentError
      # Can't parse timestamp, include the job
      true
    end
  end

  def get_exceptions_log_file
    # Read from tidewave config (consistent with get_logs tool)
    if Rails.application.config.tidewave.respond_to?(:async_job_exceptions_file)
      Pathname.new(Rails.application.config.tidewave.async_job_exceptions_file)
    else
      # Fallback to default location
      Rails.root.join("log", "async_job_exceptions.log")
    end
  end

  def get_runs_log_file
    # Read from tidewave config (consistent with get_logs tool)
    if Rails.application.config.tidewave.respond_to?(:async_job_runs_file)
      Pathname.new(Rails.application.config.tidewave.async_job_runs_file)
    else
      # Fallback to default location
      Rails.root.join("log", "async_job_runs.log")
    end
  end

  def not_found_help(source)
    if source == "runs"
      "Enable runs logging with config.tidewave.async_job_log_runs = true"
    else
      "Enable exception logging with config.tidewave.async_job_log_exceptions = true"
    end
  end

  def parse_async_job_logs(log_file, limit, grep_pattern)
    jobs = []
    current_job = nil
    in_backtrace = false
    regex = grep_pattern ? Regexp.new(grep_pattern, Regexp::IGNORECASE) : nil

    # Collect lines from tail (newest to oldest)
    lines = []
    tail_lines(log_file) do |line|
      lines << line
      break if lines.size >= limit * 20 # Get enough lines to parse limit jobs
    end

    # Reverse to parse forward (oldest to newest in this batch)
    lines.reverse!

    lines.each do |line|
      # New job entry
      if line.match(/\[(ASYNC_JOB_(?:EXCEPTION|SUCCESS))\] \[([^\]]+)\] (.+)/)
        # Save previous job
        if current_job && grep_match?(current_job, regex)
          jobs << current_job
        end

        current_job = {
          type: $1.include?("EXCEPTION") ? "exception" : "success",
          request_id: $2,
          job_class: $3.strip,
          backtrace: []
        }
        in_backtrace = false

      elsif current_job
        # Parse job fields
        if line.match(/^Message: (.+)/)
          current_job[:message] = $1.strip
          in_backtrace = false
        elsif line.match(/^Job ID: (.+)/)
          current_job[:job_id] = $1.strip
        elsif line.match(/^Queue: (.+)/)
          current_job[:queue] = $1.strip
        elsif line.match(/^Duration: (.+)/)
          current_job[:duration] = $1.strip
        elsif line.match(/^Arguments: (.+)/)
          current_job[:arguments] = $1.strip
        elsif line.match(/^Enqueued At: (.+)/)
          current_job[:enqueued_at] = $1.strip
        elsif line.match(/^Backtrace:/)
          in_backtrace = true
        elsif in_backtrace && line.strip.present?
          current_job[:backtrace] << line.strip
        end
      end
    end

    # Save last job
    if current_job && grep_match?(current_job, regex)
      jobs << current_job
    end

    # Reverse to show newest-first
    jobs.reverse!

    jobs
  end

  def grep_match?(job, regex)
    return true unless regex

    # Search in job_class, message, queue, arguments
    [
      job[:job_class],
      job[:message],
      job[:queue],
      job[:arguments],
      job[:backtrace]&.join(" ")
    ].compact.any? { |field| field.match?(regex) }
  end

  # Reuse efficient tail implementation from GetLogs
  def tail_lines(file_path)
    File.open(file_path, "rb") do |file|
      file.seek(0, IO::SEEK_END)
      file_size = file.pos
      return if file_size == 0

      buffer_size = [ 4096, file_size ].min
      pos = file_size
      buffer = ""

      while pos > 0 && buffer.count("\n") < 10000 # Safety limit
        # Move back by buffer_size or to beginning of file
        seek_pos = [ pos - buffer_size, 0 ].max
        file.seek(seek_pos)

        # Read chunk
        chunk = file.read(pos - seek_pos)
        buffer = chunk + buffer
        pos = seek_pos

        # Extract complete lines from buffer
        lines = buffer.split("\n")

        # Keep the first partial line (if any) for next iteration
        if pos > 0 && !buffer.start_with?("\n")
          buffer = lines.shift || ""
        else
          buffer = ""
        end

        # Yield lines in reverse order (last to first)
        lines.reverse_each do |line|
          yield line + "\n" unless line.empty?
        end

        break if pos == 0
      end

      # Handle any remaining buffer content
      unless buffer.empty?
        yield buffer + "\n"
      end
    end
  end
  end
end
