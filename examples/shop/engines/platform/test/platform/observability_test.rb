require "test_helper"

module Platform
  class ObservabilityTest < ActiveSupport::TestCase
    class Refused < StandardError
      include FailedPrecondition
    end

    class ContextProbeJob < ApplicationJob
      def perform = Rails.event.notify("platform.probe")
    end

    test "every reported error becomes one structured event, saying whether it was expected" do
      assert_event_reported("platform.error_reported", payload: { error_class: Refused.name, category: "FailedPrecondition", expected: true }) do
        Rails.error.report(Refused.new("no"))
      end
      assert_event_reported("platform.error_reported", payload: { error_class: "RuntimeError", category: nil, expected: false, severity: :warning }) do
        Rails.error.report(RuntimeError.new("broken"), severity: :warning)
      end
    end

    test "a job's events carry its job and flow" do
      event = assert_event_reported("platform.probe") { ContextProbeJob.perform_now }

      assert_equal %i[ causation_id correlation_id job_id ], event[:context].keys.sort
      assert event[:context][:correlation_id]
    end

    test "the JSON event log writes one object per line, without where in the code it came from" do
      io = StringIO.new
      EventLog::JsonLines.new(io).emit(name: "platform.probe", payload: { id: 1 }, tags: {}, context: { request_id: "r-1" }, timestamp: 1, source_location: { lineno: 1 })

      assert_equal({ "name" => "platform.probe", "payload" => { "id" => 1 }, "tags" => {}, "context" => { "request_id" => "r-1" }, "timestamp" => 1 }, JSON.parse(io.string))
    end

    test "the text event log logs an expected error as information, and an unexpected one at its severity" do
      lines = with_log do
        EventLog::Text.new.emit(name: "platform.error_reported", payload: { expected: true, severity: :warning }, context: {})
        EventLog::Text.new.emit(name: "platform.error_reported", payload: { expected: false, severity: :warning }, context: {})
        EventLog::Text.new.emit(name: "platform.error_reported", payload: { expected: false, severity: :error }, context: { request_id: "r-1" })
      end

      assert_equal [ "INFO", "WARN", "ERROR" ], lines.map { |line| line.split.first }
      assert_includes lines.last, "request_id=r-1"
    end

    private
      def with_log
        io = StringIO.new
        logger = ActiveSupport::Logger.new(io).tap { |it| it.formatter = ->(severity, *, message) { "#{severity} #{message}\n" } }
        previous, Rails.logger = Rails.logger, logger
        yield
        io.string.lines
      ensure
        Rails.logger = previous
      end
  end
end
