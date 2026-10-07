require "opentelemetry/sdk"

module Platform
  # Traces, recorded with OpenTelemetry. Each environment chooses where they go
  # (config.platform.traces): :otlp, to the collector OTEL_EXPORTER_OTLP_ENDPOINT names; :memory,
  # kept for tests to read (exporter); or :none, not recorded at all.
  module Traces
    # Spans for EventRail's work, from its notifications: an event published or staged, handed to
    # a subscriber, handled.
    EVENT_RAIL = %w[ publish.event_rail stage.event_rail enqueue_subscriber.event_rail perform_subscriber.event_rail ].freeze

    mattr_reader :exporter

    def self.configure(choice)
      processor =
        case choice
        when :none then return
        when :otlp
          require "opentelemetry/exporter/otlp"
          OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(OpenTelemetry::Exporter::OTLP::Exporter.new)
        when :memory
          @@exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
          OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
        else raise ArgumentError, "config.platform.traces names no trace exporter: #{choice.inspect}"
        end

      OpenTelemetry::SDK.configure do |config|
        config.service_name = Rails.application.class.module_parent_name.underscore
        config.logger = Rails.logger # the exporter's complaints go through the shop's log
        config.add_span_processor(processor)
        config.use "OpenTelemetry::Instrumentation::Rack"
        config.use "OpenTelemetry::Instrumentation::ActionPack"
        config.use "OpenTelemetry::Instrumentation::ActiveRecord"
        # A job links to the trace that enqueued it rather than joining it: a flow that runs for
        # days would otherwise be one trace.
        config.use "OpenTelemetry::Instrumentation::ActiveJob", span_naming: :job_class, propagation_style: :link
        config.use "OpenTelemetry::Instrumentation::ActiveSupport"
        config.use "OpenTelemetry::Instrumentation::Net::HTTP"
      end

      tracer = OpenTelemetry.tracer_provider.tracer("event_rail")
      EVENT_RAIL.each { |name| OpenTelemetry::Instrumentation::ActiveSupport.subscribe(tracer, name) }
    end

    # The trace context running now, to store with work that leaves later; nil outside a trace.
    def self.carrier = {}.tap { |carrier| OpenTelemetry.propagation.inject(carrier) }.presence

    # Runs the block in the trace a carrier was taken in.
    def self.within(carrier, &block)
      return yield if carrier.blank?

      OpenTelemetry::Context.with_current(OpenTelemetry.propagation.extract(carrier), &block)
    end
  end
end
