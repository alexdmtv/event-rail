require "test_helper"
require "event_rail/test_helper"

EventRail::TestHelper.declare do
  module Platform
    module ObservabilityFixtures
      class Noticed < EventRail::Event
        event_type "platform_tests.observed"
        version 1
        default_source "shop.platform_tests"

        attribute :customer_email, :string
        identity_by :customer_email
      end
    end
  end
end

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

    test "an expected error is expected only once answered: escaping a job, it is a failure" do
      assert_event_reported("platform.error_reported", payload: { category: "FailedPrecondition", expected: false, handled: false }) do
        Rails.error.report(Refused.new("no"), handled: false)
      end
    end

    test "an error event carries the details its report names, and nothing else from the report's context" do
      event = assert_event_reported("platform.error_reported", payload: { details: { staged_job_id: "j-1" } }) do
        Rails.error.report(RuntimeError.new("broken"), context: { details: { staged_job_id: "j-1" }, customer_email: "a@example.com" })
      end

      assert_not_includes event[:payload].to_s, "a@example.com"
    end

    test "an event log that fails can't fail reporting an error, as it would by reporting its own failure forever" do
      sink = Class.new { def emit(_event) = raise("the event log is down") }.new
      Rails.event.raise_on_error = false # as in production
      Rails.event.subscribe(sink)

      assert_nothing_raised { Rails.error.report(RuntimeError.new("broken")) }
    ensure
      Rails.event.unsubscribe(sink)
      Rails.event.raise_on_error = Rails.configuration.consider_all_requests_local
    end

    test "a job's arguments are logged as references: a record by its GlobalID, a domain event by its type and ID, anything else filtered" do
      job = Class.new(ActiveJob::Base) { def self.name = "ArgumentProbeJob"; def perform(*) = nil }
      job.log_arguments = true # as the JSON log turns it on
      record = StagedJob.create!(job_id: "j-1", job_class: "ProbeJob", payload: {}, created_at: Time.current)
      event = ObservabilityFixtures::Noticed.new(customer_email: "ada@example.com")

      started = assert_event_reported("active_job.started", payload: { job_class: "ArgumentProbeJob" }) { job.perform_now(record, event, "ada@example.com") }
      line = JSON.parse(with_log(EventLog::JsonFormatter.new) { EventLog::Json.new.emit(started) }.sole)

      assert_equal [ record.to_global_id.to_s, "platform_tests.observed #{event.id}", "[FILTERED]" ], line.dig("payload", "arguments")
      assert_not_includes line.to_s, "ada@example.com"
    end

    test "jobs log no arguments where no JSON log makes them references" do
      assert_not ActiveJob::Base.log_arguments
    end

    test "a request's parameters are logged by key, with a value only for the keys named safe" do
      started = { name: "action_controller.request_started", context: {}, tags: {},
                  payload: { controller: "CartsController", params: { "customer_name" => "Ada", "cart_id" => "5", "items" => [ { "sku" => "MUG", "quantity" => 2 } ] } } }
      line = JSON.parse(with_log(EventLog::JsonFormatter.new) { EventLog::Json.new.emit(started) }.sole)

      assert_equal({ "customer_name" => "[FILTERED]", "cart_id" => "5", "items" => [ { "sku" => "MUG", "quantity" => 2 } ] }, line.dig("payload", "params"))
    end

    test "the JSON formatter never raises: binary strings, bad keys and objects become a line" do
      formatter = EventLog::JsonFormatter.new
      lines = [
        formatter.call("INFO", Time.current, nil, "provider answered #{"\xFF".b}"),
        formatter.call("INFO", Time.current, nil, { name: "platform.probe", payload: { "caf\xFF".dup.force_encoding("UTF-8") => 1 } }),
        formatter.call("INFO", Time.current, nil, { name: "platform.probe", payload: Struct.new(:body).new("\xFF".b) })
      ]

      lines.each { |line| assert JSON.parse(line) }
    end

    test "a job's events carry its job and flow" do
      event = assert_event_reported("platform.probe") { ContextProbeJob.perform_now }

      assert_equal %i[ causation_id correlation_id job_id message_id ], event[:context].keys.sort
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

    test "with the JSON formatter, a string that isn't valid UTF-8 doesn't lose the line" do
      lines = with_log(EventLog::JsonFormatter.new) { Rails.logger.info("caf\xFF".dup.force_encoding("UTF-8")) }

      assert_equal "caf\uFFFD", JSON.parse(lines.sole)["message"]
    end

    test "a job that runs every second is quiet in the event log, unless it fails" do
      relay = { name: "active_job.completed", payload: { job_class: "Platform::StagedJobRelayJob" } }

      assert_not EventLog.written?(relay)
      assert EventLog.written?(relay.deep_merge(payload: { exception_class: "RuntimeError" }))
      assert EventLog.written?(relay.deep_merge(payload: { job_class: "Orders::ConfirmJob" }))
    end

    test "Rails' event for an error a controller answered isn't written: the shop's error event says more" do
      assert_not EventLog.written?(name: "action_controller.rescue_from_handled", payload: { exception_class: "Platform::NotFound" })
    end

    test "an event's level comes from what it is: a failure is an error, everything else information" do
      assert_equal :error, EventLog.level(name: "active_job.retry_stopped", payload: {})
      assert_equal :error, EventLog.level(name: "active_job.discarded", payload: {})
      assert_equal :error, EventLog.level(name: "active_job.completed", payload: { exception_class: "RuntimeError" })
      assert_equal :info, EventLog.level(name: "active_job.completed", payload: {})
      assert_equal :info, EventLog.level(name: "payments.capture_superseded", payload: {})
    end

    test "the text event log shows the shop's own events, every module's included, and leaves Rails' to its text lines" do
      assert EventLog.own?("event_rail.staged")
      assert EventLog.own?("platform.error_reported")
      assert EventLog.own?("payments.capture_superseded")
      assert_not EventLog.own?("active_record.sql")
      assert_not EventLog.own?("action_controller.request_completed")
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
