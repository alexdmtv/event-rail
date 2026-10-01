# Collects what EventRail published or staged while a block ran, through its documented
# notifications.
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
    ActiveSupport::Notifications.subscribed(callback, /\A(publish|stage)\.event_rail\z/, &block)
    publications
  end
end
