module Platform
  # EventRail's notifications as structured events, so the event log shows each domain event
  # published, staged, handed to a subscriber and handled, joined by its correlation. In the
  # shop rather than the gem: this Rails 8.1 API is still settling, and the gem supports 7.2.
  class EventRailEvents < ActiveSupport::StructuredEventSubscriber
    attach_to :event_rail

    def publish(event) = emit_event("event_rail.published", details(event))
    def stage(event) = emit_event("event_rail.staged", details(event))
    def enqueue_subscriber(event) = emit_event("event_rail.subscriber_enqueued", details(event))
    def perform_subscriber(event) = emit_event("event_rail.subscriber_performed", details(event))

    private
      def details(event)
        exception_class, exception_message = event.payload[:exception]
        # Without what other subscribers keep in the payload, such as OpenTelemetry's span.
        event.payload.except(:exception, :exception_object).reject { |key, _| key.start_with?("__") }
          .merge(duration_ms: event.duration.round(2), exception_class:, exception_message:).compact
      end
  end
end
