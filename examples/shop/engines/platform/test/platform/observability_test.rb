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

    test "with the JSON formatter, an event is one object per line, without where in the code it came from" do
      lines = with_log(EventLog::JsonFormatter.new) do
        EventLog::Json.new.emit(name: "platform.probe", payload: { id: 1 }, tags: {}, context: { request_id: "r-1" }, timestamp: 1, source_location: { lineno: 1 })
      end

      line = JSON.parse(lines.sole)
      assert_equal [ "INFO", "platform.probe", { "id" => 1 }, { "request_id" => "r-1" } ], line.values_at("level", "name", "payload", "context")
      assert_nil line["source_location"]
    end

    test "with the JSON formatter, any other line is one object too, with the request's or job's context" do
      Observability.set_context(request_id: "r-1")
      lines = with_log(EventLog::JsonFormatter.new) { Rails.logger.warn("a gem warns") }

      assert_equal [ "WARN", "a gem warns", { "request_id" => "r-1" } ], JSON.parse(lines.sole).values_at("level", "message", "context")
    ensure
      Rails.event.clear_context
    end

    test "the text event log logs an expected error as information, and an unexpected one at its severity" do
      lines = with_log do
        EventLog::Text.new.emit(name: "platform.error_reported", payload: { expected: true, severity: :warning }, context: {})
        EventLog::Text.new.emit(name: "platform.error_reported", payload: { expected: false, severity: :warning }, context: {})
        EventLog::Text.new.emit(name: "platform.error_reported", payload: { expected: false, severity: :error }, context: { request_id: "r-1" })
      end

      assert_equal [ "INFO", "WARN", "ERROR" ], lines.map { |line| line.split.first }
    end

    test "the text event log tells an event as a short sentence, with its flow" do
      lines = with_log do
        EventLog::Text.new.emit(name: "event_rail.staged", context: {}, payload: { event_type: "orders.order_placed", event_version: 2, subscriber_count: 1, duration_ms: 1.7, correlation_id: "e18aacc2-aac2" })
        EventLog::Text.new.emit(name: "platform.error_reported", context: { correlation_id: "abcdef123" }, payload: { expected: true, error_class: "Platform::InvalidInput", category: "InvalidArgument", message: "items can't be blank" })
      end

      assert_equal "INFO   EventRail staged orders.order_placed v2 for 1 subscriber (1.7ms) [flow e18aacc2]", lines.first.chomp
      assert_equal "INFO   Refused: Platform::InvalidInput (InvalidArgument): items can't be blank [flow abcdef12]", lines.last.chomp
    end

    private
      def with_log(formatter = ->(severity, *, message) { "#{severity} #{message}\n" })
        io = StringIO.new
        logger = ActiveSupport::Logger.new(io).tap { |it| it.formatter = formatter }
        previous, Rails.logger = Rails.logger, logger
        yield
        io.string.lines
      ensure
        Rails.logger = previous
      end
  end
end
