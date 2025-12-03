# frozen_string_literal: true

class Tidewave::Tools::GetLogs < Tidewave::Tools::Base
  tool_name "get_logs"
  description <<~DESCRIPTION
    Returns all log output, excluding logs that were caused by other tool calls.

    Use this tool to check for request logs or potentially logged errors.
  DESCRIPTION

  arguments do
    required(:tail).filled(:integer).description("The number of log entries to return from the end of the log")
    optional(:grep).filled(:string).description("Filter logs with the given regular expression (case insensitive). E.g. \"error\" when you want to capture errors in particular")
    optional(:since).filled(:string).description("Only show logs since timestamp. Supports: '15m', '1h', '6h', '1d', '1w' or ISO8601 timestamp (e.g. '2024-12-02T23:00:00')")
  end

  def call(tail:, grep: nil, since: nil)
    # Use configured production log path (app can override via config.tidewave.production_log_file)
    # Falls back to Rails.root/log/#{Rails.env}.log
    log_file = if Rails.application.config.tidewave.respond_to?(:production_log_file)
      Pathname.new(Rails.application.config.tidewave.production_log_file)
    else
      Rails.root.join("log", "#{Rails.env}.log")
    end

    unless File.exist?(log_file)
      return <<~MSG.strip
        Log file not found at: #{log_file}

        Debug info:
        - Rails.env: #{Rails.env}
        - Rails.root: #{Rails.root}

        Possible causes:
        1. App hasn't processed any requests yet (no logs written)
        2. Log directory permissions issue
        3. Custom log path not configured correctly
      MSG
    end

    file_size = File.size(log_file)
    if file_size == 0
      return <<~MSG.strip
        Log file exists but is empty: #{log_file}

        This means no logs have been written yet.
        Try making a request to your app first.
      MSG
    end

    regex = Regexp.new(grep, Regexp::IGNORECASE) if grep
    cutoff_time = parse_since(since) if since
    matching_lines = []

    tail_lines(log_file) do |line|
      next if cutoff_time && !line_after_cutoff?(line, cutoff_time)

      if regex.nil? || line.match?(regex)
        matching_lines.push(line)
        break if matching_lines.size >= tail
      end
    end

    # Reverse to show oldest-first (chronological), with newest at bottom
    matching_lines.reverse!

    if matching_lines.empty?
      return <<~MSG.strip
        No matching logs found in #{log_file}

        File size: #{file_size} bytes
        Filter: #{grep || 'none'}
        Since: #{since || 'none'}
        Tail: #{tail} lines

        Try:
        - Remove the filter to see all logs
        - Increase tail count
        - Make requests to generate more logs
      MSG
    end

    matching_lines.join
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
      # Parse timestamp - use Time.parse for consistent timezone handling with log lines
      Time.parse(since_param)
    end
  rescue ArgumentError => e
    # Invalid timestamp format, return nil to skip filtering
    Rails.logger.warn "[GetLogs] Invalid since parameter: #{since_param} - #{e.message}"
    nil
  end

  def line_after_cutoff?(line, cutoff_time)
    # Rails production.log format: "I, [2024-12-02T23:15:42.123456 #12345]"
    # Also handles: "[2024-12-02 23:15:42]"
    if match = line.match(/(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})/)
      begin
        line_time = Time.parse(match[1])
        line_time >= cutoff_time
      rescue ArgumentError
        # Can't parse timestamp, include the line (might be continuation)
        true
      end
    else
      # No timestamp found - include the line to preserve backtraces/continuation lines.
      # Trade-off: may include stray continuation lines from older entries, but losing
      # backtrace info from recent exceptions is worse for debugging.
      true
    end
  end

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
