# frozen_string_literal: true

require 'rails'

describe Tidewave::Tools::GetLogs do
  describe ".tool_name" do
    it "returns the correct tool name" do
      expect(described_class.tool_name).to eq("get_logs")
    end
  end

  describe "#call" do
    let(:log_file_path) { "spec/fixtures/fake_development_log.log" }
    let(:log_file_content) { File.read(log_file_path) }

    before do
      allow(Rails).to receive_message_chain(:root, :join).and_return(Pathname.new(log_file_path))
    end

    context "without grep filter" do
      it "returns the correct logs" do
        expect(described_class.new.call(tail: 10)).to eq(log_file_content.lines.last(10).join)
      end

      it "returns all lines when tail is larger than file" do
        total_lines = log_file_content.lines.count
        expect(described_class.new.call(tail: total_lines + 10)).to eq(log_file_content)
      end
    end

    context "with grep filter" do
      it "filters logs with the given regular expression" do
        result = described_class.new.call(tail: 100, grep: "Never gonna")
        lines = result.lines

        expect(lines.all? { |line| line.match?(/Never gonna/) }).to be true
        expect(lines.size).to be > 0
      end

      it "respects tail limit after filtering" do
        result = described_class.new.call(tail: 3, grep: "Never gonna")
        lines = result.lines
        expect(lines.size).to eq(3)
      end

      it "works with case-insensitive regex" do
        result = described_class.new.call(tail: 100, grep: "NEVER GONNA")
        lines = result.lines

        expect(lines.all? { |line| line.match?(/Never gonna/i) }).to be true
        expect(lines.size).to be > 0
      end

      it "works with complex regex patterns" do
        result = described_class.new.call(tail: 100, grep: "never gonna (give|let)")
        lines = result.lines

        expect(lines.all? { |line| line.match?(/Never gonna (give|let)/i) }).to be true
        expect(lines.size).to be > 0
      end
    end

    context "when log file doesn't exist" do
      before do
        # Stub Rails.application.config.tidewave to not respond to production_log_file
        # so it falls back to Rails.root.join
        allow(Rails).to receive_message_chain(:application, :config, :tidewave, :respond_to?)
          .with(:production_log_file).and_return(false)
        allow(Rails).to receive_message_chain(:root, :join).and_return(Pathname.new("nonexistent.log"))
      end

      it "returns appropriate message" do
        result = described_class.new.call(tail: 10)
        # New implementation returns detailed message with debug info
        expect(result).to include("Log file not found")
        expect(result).to include("nonexistent.log")
      end
    end

    context "with since parameter (time-based filtering)" do
      let(:timestamped_log_path) { "spec/fixtures/timestamped_log.log" }
      let(:frozen_time) { Time.parse("2024-12-02T23:00:00Z") }

      before do
        # Stub to use the production_log_file config (simplest path)
        tidewave_config = double('tidewave_config')
        allow(tidewave_config).to receive(:respond_to?).with(:production_log_file).and_return(true)
        allow(tidewave_config).to receive(:production_log_file).and_return(timestamped_log_path)
        allow(Rails).to receive_message_chain(:application, :config, :tidewave).and_return(tidewave_config)
      end

      it "filters logs using ISO8601 timestamp (1 hour)" do
        # Use timestamp without Z suffix to match local time parsing of log lines
        result = described_class.new.call(tail: 100, since: '2024-12-02T22:00:00')
        lines = result.lines

        # Should include logs from 22:00:00 onwards (5 lines: 22:00, 22:15, 22:30, 22:45, 23:00)
        expect(lines.size).to eq(5)
        expect(lines.all? { |line| line.include?('22:') || line.include?('23:') }).to be true
      end

      it "filters logs using ISO8601 timestamp (2 hours)" do
        result = described_class.new.call(tail: 100, since: '2024-12-02T21:00:00')
        lines = result.lines

        # Should include logs from 21:00:00 onwards (7 lines)
        expect(lines.size).to eq(7)
      end

      it "filters logs using ISO8601 timestamp (30 minutes)" do
        result = described_class.new.call(tail: 100, since: '2024-12-02T22:30:00')
        lines = result.lines

        # Should only include logs from 22:30:00 onwards (3 lines: 22:30, 22:45, 23:00)
        expect(lines.size).to eq(3)
      end

      it "combines since with grep filter" do
        result = described_class.new.call(tail: 100, since: '2024-12-02T22:00:00', grep: 'Very recent')
        lines = result.lines

        # Should only include "Very recent" logs from 22:00 onwards (2 lines: 22:45, 23:00)
        expect(lines.size).to eq(2)
        expect(lines.all? { |line| line.include?('Very recent') }).to be true
      end

      it "returns empty when since is after all logs" do
        result = described_class.new.call(tail: 100, since: '2024-12-02T23:30:00')

        expect(result).to include("No matching logs found")
        expect(result).to include("Since: 2024-12-02T23:30:00")
      end

      it "handles invalid since parameter gracefully" do
        # Should not crash, just ignore the invalid parameter
        expect {
          described_class.new.call(tail: 10, since: 'invalid')
        }.not_to raise_error
      end

      context "with relative time formats" do
        let(:now) { Time.parse("2024-12-02T23:00:00") }

        before do
          allow(Time).to receive(:now).and_return(now)
        end

        it "parses minutes format (30m)" do
          result = described_class.new.call(tail: 100, since: '30m')
          lines = result.lines

          # 30 minutes ago from 23:00 is 22:30 - should get 3 lines (22:30, 22:45, 23:00)
          expect(lines.size).to eq(3)
        end

        it "parses hours format (1h)" do
          result = described_class.new.call(tail: 100, since: '1h')
          lines = result.lines

          # 1 hour ago from 23:00 is 22:00 - should get 5 lines
          expect(lines.size).to eq(5)
        end

        it "parses hours format (2h)" do
          result = described_class.new.call(tail: 100, since: '2h')
          lines = result.lines

          # 2 hours ago from 23:00 is 21:00 - should get 7 lines
          expect(lines.size).to eq(7)
        end

        it "parses days format (1d)" do
          result = described_class.new.call(tail: 100, since: '1d')
          lines = result.lines

          # 1 day ago - all logs in fixture are from same day, should get all 10
          expect(lines.size).to eq(10)
        end

        it "parses weeks format (1w)" do
          result = described_class.new.call(tail: 100, since: '1w')
          lines = result.lines

          # 1 week ago - all logs in fixture are from same day, should get all 10
          expect(lines.size).to eq(10)
        end
      end
    end

    context "with multi-line log entries (backtraces)" do
      let(:multiline_log_path) { "spec/fixtures/multiline_log.log" }

      before do
        tidewave_config = double('tidewave_config')
        allow(tidewave_config).to receive(:respond_to?).with(:production_log_file).and_return(true)
        allow(tidewave_config).to receive(:production_log_file).and_return(multiline_log_path)
        allow(Rails).to receive_message_chain(:application, :config, :tidewave).and_return(tidewave_config)
      end

      it "preserves backtrace lines when filtering by since" do
        # Filter to include the error at 22:30 but not the log at 22:00
        result = described_class.new.call(tail: 100, since: '2024-12-02T22:15:00')
        lines = result.lines

        # Should include: error line, 3 backtrace lines, recovery line = 5 lines
        expect(lines.size).to eq(5)
        expect(result).to include("RuntimeError")
        expect(result).to include("/app/models/user.rb")
        expect(result).to include("/app/controllers/users_controller.rb")
        expect(result).to include("Recovery complete")
      end

      it "preserves backtrace when combined with grep" do
        result = described_class.new.call(tail: 100, since: '2024-12-02T22:15:00', grep: 'RuntimeError')

        # grep matches the error line, and continuation lines follow
        expect(result).to include("RuntimeError")
      end
    end
  end
end
