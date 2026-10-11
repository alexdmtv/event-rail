require "opentelemetry/sdk"

module Platform
  # Traces, recorded with OpenTelemetry and configured by its standard variables
  # (OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES, OTEL_TRACES_SAMPLER,
  # OTEL_SDK_DISABLED). Each environment chooses whether they are recorded (config.platform.traces):
  # :otlp, exported as OTEL_TRACES_EXPORTER says, over OTLP unless it says otherwise; :memory, kept
  # for tests to read (exporter); or :none.
  module Traces
    # Spans for EventRail's work, from its notifications: an event published or staged, handed to
    # a subscriber, handled.
    EVENT_RAIL = %w[ publish.event_rail stage.event_rail enqueue_subscriber.event_rail perform_subscriber.event_rail ].freeze
    # A process exiting sends what it has buffered first, and waits no longer than this, well within
    # Solid Queue's five seconds: the exporter's retries sleep without looking at a deadline, so
    # a collector that's down would otherwise hold the exit for up to twenty seconds.
    SHUTDOWN_TIMEOUT = 3

    mattr_reader :exporter

    # Notifications that become spans. A module names its own, the operations it times (as
    # Payments does the provider's calls), without depending on OpenTelemetry; they are subscribed
    # only once traces are configured, since a span subscribed before would record nothing.
    def self.span(name) = spans << name
    def self.spans = @spans ||= EVENT_RAIL.dup

    def self.configure(choice)
      case choice
      when :none then return
      when :otlp then require "opentelemetry/exporter/otlp"
      when :memory then @@exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
      else raise ArgumentError, "config.platform.traces names no trace exporter: #{choice.inspect}"
      end

      OpenTelemetry::SDK.configure do |config|
        # A default only: what the environment names wins (shop/web, shop/jobs per role).
        config.service_name = "shop" unless ENV["OTEL_SERVICE_NAME"]
        config.logger = Rails.logger # the exporter's complaints go through the shop's log
        config.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)) if choice == :memory
        config.use "OpenTelemetry::Instrumentation::Rack", untraced_endpoints: %w[ /up /up/outbox ] # health checks
        config.use "OpenTelemetry::Instrumentation::ActionPack"
        config.use "OpenTelemetry::Instrumentation::ActiveRecord"
        # A job links to the trace that enqueued it rather than joining it: a flow that runs for
        # days would otherwise be one trace.
        config.use "OpenTelemetry::Instrumentation::ActiveJob", span_naming: :job_class, propagation_style: :link
        config.use "OpenTelemetry::Instrumentation::ActiveSupport"
        config.use "OpenTelemetry::Instrumentation::Net::HTTP"
      end

      # Not configured when OTEL_SDK_DISABLED is set, or when configuring failed, which the SDK
      # logs rather than raises.
      provider = OpenTelemetry.tracer_provider
      return unless provider.is_a?(OpenTelemetry::SDK::Trace::TracerProvider)

      # Tests sample everything, whatever a developer's shell sets.
      sampler = choice == :memory ? OpenTelemetry::SDK::Trace::Samplers::ALWAYS_ON : provider.sampler
      provider.sampler = OpenTelemetry::SDK::Trace::Samplers.parent_based(root: EntryPoints.new(sampler))
      at_exit { shutdown(provider) } # forked processes inherit it

      tracer = provider.tracer("shop")
      spans.each { |name| OpenTelemetry::Instrumentation::ActiveSupport.subscribe(tracer, name) }
    end

    # A trace starts where work enters the shop, a request or a job; a query or a transaction
    # outside one starts none, or Solid Queue's polling would start one every second. Nor does a
    # job that runs every second (Platform::EventLog::QUIET_JOBS), nor a rake task, runner script
    # or console, whose spans are internal. Inside a trace, every span is recorded.
    class EntryPoints
      KINDS = %i[ server consumer ].freeze

      # sampler decides for the traces that may start: the one OTEL_TRACES_SAMPLER chose, which
      # samples a ratio in production.
      def initialize(sampler) = @sampler = sampler

      def should_sample?(trace_id:, parent_context:, links:, name:, kind:, attributes:)
        entry = KINDS.include?(kind) && EventLog::QUIET_JOBS.none? { |job| name.start_with?("#{job} ") }
        (entry ? @sampler : OpenTelemetry::SDK::Trace::Samplers::ALWAYS_OFF).should_sample?(trace_id:, parent_context:, links:, name:, kind:, attributes:)
      end

      def description = "EntryPoints{#{@sampler.description}}"
    end

    # Best effort: spans still buffered after the wait are lost.
    def self.shutdown(provider)
      Thread.new { provider.shutdown(timeout: SHUTDOWN_TIMEOUT) }.join(SHUTDOWN_TIMEOUT + 0.5)
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
