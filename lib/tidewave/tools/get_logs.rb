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
  end

  def call(tail:, grep: nil)
    # Check for mounted mode first (dual logger writes here)
    # Fallback to image mode (/rails/log/) if not mounted
    log_file = if ENV['USE_MOUNTED_VIBES'] == 'true' && Dir.exist?('/mnt/data/code')
      Pathname.new('/mnt/data/code/log/production.log')
    else
      Rails.root.join("log", "#{Rails.env}.log")
    end
    
    unless File.exist?(log_file)
      return <<~MSG.strip
        Log file not found at: #{log_file}
        
        Debug info:
        - Rails.env: #{Rails.env}
        - USE_MOUNTED_VIBES: #{ENV['USE_MOUNTED_VIBES'] || 'not set'}
        - /mnt/data/code exists: #{Dir.exist?('/mnt/data/code')}
        - Rails.root: #{Rails.root}
        
        Possible causes:
        1. App hasn't processed any requests yet (no logs written)
        2. Dual logger not initialized (check boot logs for "Dual logger initialized")
        3. Log directory permissions issue (check chown rails:rails)
      MSG
    end
    
    file_size = File.size(log_file)
    if file_size == 0
      return <<~MSG.strip
        Log file exists but is empty: #{log_file}
        
        This means:
        - Dual logger initialized successfully
        - But no logs have been written yet
        - Try making a request to your app first
        - Or trigger an exception to test logging
      MSG
    end

    regex = Regexp.new(grep, Regexp::IGNORECASE) if grep
    matching_lines = []

    tail_lines(log_file) do |line|
      if regex.nil? || line.match?(regex)
        matching_lines.push(line) # FIXED: push instead of unshift to maintain newest-first order
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
