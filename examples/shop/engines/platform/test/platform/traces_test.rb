require "test_helper"

module Platform
  class TracesTest < ActiveSupport::TestCase
    class ProbeJob < ApplicationJob
      def perform = nil
    end

    def tracer = OpenTelemetry.tracer_provider.tracer("test")
    def spans = Traces.exporter.finished_spans
    def stage = StagedJob.transaction { ProbeJob.stage }

    def performed_span
      perform_enqueued_jobs
      spans.find { |span| span.name == "#{ProbeJob.name} process" }
    end

    test "a job staged in a trace and handed over at the commit links to that trace" do
      request = tracer.in_span("request", kind: :server) { |span| stage.then { span.context.trace_id } }

      assert_equal request, performed_span.links.sole.span_context.trace_id
    end

    test "a job the relay hands over later is handed over in a trace of its own that links to the one it was staged in" do
      request = tracer.in_span("request", kind: :server) { |span| refusing_enqueue { stage }.then { span.context.trace_id } }
      relay_staged_jobs

      job = performed_span
      hand_over = spans.find { |span| span.name == "#{ProbeJob.name} hand over" }
      assert_equal hand_over.trace_id, job.links.sole.span_context.trace_id, "the job links to its hand-over"
      assert_equal request, hand_over.links.sole.span_context.trace_id, "which links to the request that staged it"
      assert_equal 3, [ request, hand_over.trace_id, job.trace_id ].uniq.size, "each hop a trace of its own, none joined late"
    end

    test "nothing names a trace that isn't recorded: no trace ID in the log, no context stored" do
      tracer.in_span("unsampled work") do # an internal root, which starts no trace
        assert_empty Observability.current_trace
        assert_nil Traces.carrier
      end
    end

    test "the stored trace context carries no baggage" do
      OpenTelemetry::Context.with_current(OpenTelemetry::Baggage.set_value("customer", "ada@example.com")) do
        carrier = tracer.in_span("request", kind: :server) { Traces.carrier }
        assert_equal %w[ traceparent ], carrier.keys
      end
    end

    test "a job's span carries its flow, so a trace can be found by it" do
      perform_enqueued_jobs { EventRail.with_context(message_id: "checkout-k") { stage } }

      assert_equal "checkout-k", performed_span.attributes["correlation_id"]
      assert performed_span.attributes["job_id"]
    end

    test "a log line written inside a span names its trace and span" do
      io = StringIO.new
      logger = ActiveSupport::Logger.new(io).tap { |it| it.formatter = EventLog::JsonFormatter.new }

      span = tracer.in_span("work", kind: :server) { |span| logger.info("working").then { span.context } }

      assert_equal [ span.hex_trace_id, span.hex_span_id ], JSON.parse(io.string).values_at("trace_id", "span_id")
    end

    test "a trace starts only where work enters: a request or a job, not a query or the every-second relay" do
      StagedJob.count
      tracer.in_span("internal work") { }
      StagedJobRelayJob.perform_now

      assert_empty spans
    end

    test "a trace that may start is left to the sampler the environment chose" do
      sampler = Traces::EntryPoints.new(OpenTelemetry::SDK::Trace::Samplers::ALWAYS_OFF)
      result = sampler.should_sample?(trace_id: OpenTelemetry::Trace.generate_trace_id, parent_context: nil, links: [], name: "GET /orders", kind: :server, attributes: {})

      assert_not result.sampled?
    end
  end
end
