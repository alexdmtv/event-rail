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
      spans.find { |span| span.kind == :consumer && span.name.start_with?(ProbeJob.name) }
    end

    test "a job staged in a trace and handed over at the commit links to that trace" do
      request = tracer.in_span("request", kind: :server) { |span| stage.then { span.context.trace_id } }

      assert_equal request, performed_span.links.sole.span_context.trace_id
    end

    test "a job the relay hands over later links to the trace it was staged in, not the relay's" do
      request = tracer.in_span("request", kind: :server) { |span| refusing_enqueue { stage }.then { span.context.trace_id } }
      relay = tracer.in_span("relay", kind: :consumer) { |span| relay_staged_jobs.then { span.context.trace_id } }

      job = performed_span
      assert_equal request, job.links.sole.span_context.trace_id
      assert_not_includes [ request, relay ], job.trace_id, "a trace of its own, linked rather than joined"
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
