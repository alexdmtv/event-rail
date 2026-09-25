# Collects what EventRail published while a block ran, through the same documented
# `publish.event_rail` notification the Observability module records flows from.
module PublicationRecorder
  Publication = Data.define(:event_type, :event_version, :event_id, :correlation_id, :causation_id)

  def record_publications(&block)
    publications = []
    callback = lambda do |event|
      payload = event.payload
      publications << Publication.new(
        event_type: payload[:event_type], event_version: payload[:event_version], event_id: payload[:event_id],
        correlation_id: payload[:correlation_id], causation_id: payload[:causation_id]
      )
    end
    ActiveSupport::Notifications.subscribed(callback, "publish.event_rail", &block)
    publications
  end
end
