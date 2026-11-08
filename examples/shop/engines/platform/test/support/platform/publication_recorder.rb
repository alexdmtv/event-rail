module Platform
  module TestSupport
    # Collects what EventRail published or staged while a block ran, payload included, so a
    # publisher's test can check what it announced.
    module PublicationRecorder
      Publication = Data.define(:event_type, :event_version, :event_id, :correlation_id, :causation_id, :payload)

      mattr_accessor :recordings, default: []

      def self.note(event)
        publication = Publication.new(event_type: event.event_type, event_version: event.version, event_id: event.id,
          correlation_id: event.correlation_id, causation_id: event.causation_id, payload: event.attributes.symbolize_keys)
        recordings.each { |recording| recording << publication }
      end

      # Sees every event as EventRail stamps it, while any recording is open.
      EventRail.singleton_class.prepend(Module.new do
        def publish(...) = super.tap { |publication| PublicationRecorder.note(publication.event) }
        def stage(...) = super.tap { |staged| PublicationRecorder.note(staged.event) }
      end)

      def record_publications
        recording = []
        PublicationRecorder.recordings.push(recording)
        yield
        recording
      ensure
        PublicationRecorder.recordings.delete(recording)
      end
    end
  end
end
