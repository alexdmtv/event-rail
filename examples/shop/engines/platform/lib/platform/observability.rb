module Platform
  # The context every error report and structured event of a request or job carries. Rails keeps
  # one store for each, and clears both when the request or job ends.
  module Observability
    # Sets the context for the block and restores the one before after it, so a job performed
    # inside another (perform_now) doesn't leave its own behind. Rails.error's store restores the
    # keys it set; clearing it would also drop the request's or job's Current attributes.
    def self.with_context(**context)
      event_context = Rails.event.context.dup
      ActiveSupport::ExecutionContext.set(**context) do
        set_context(**context)
        yield
      end
    ensure
      Rails.event.clear_context
      Rails.event.set_context(event_context)
    end

    def self.set_context(**context)
      Rails.error.set_context(**context)
      Rails.event.set_context(context)
      # The request's or job's span carries it too, so a trace can be found by its flow.
      span = OpenTelemetry::Trace.current_span
      span.add_attributes(context.compact.to_h { |key, value| [ key.to_s, value.to_s ] }) if span.recording?
    end

    # The span running now, so a line in the log leads to its trace. Read as each line is written,
    # never set as context: the span changes within a request. Empty outside a recorded trace.
    def self.current_trace
      span = OpenTelemetry::Trace.current_span
      Traces.sampled?(span) ? { trace_id: span.context.hex_trace_id, span_id: span.context.hex_span_id } : {}
    end
  end
end
