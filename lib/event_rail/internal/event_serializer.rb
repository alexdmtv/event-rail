module EventRail
  module Internal
    # The private Active Job representation of an event.
    #
    # Private means EventRail owns it entirely: its shape is not public API, no
    # application should read or write it, and it may change under the staging
    # discipline below. The public boundary is `EventRail::Envelope`.
    #
    # Every value written is a JSON primitive, array, or string-keyed hash. That is not
    # a stylistic choice: `ObjectSerializer#serialize` is `@template.merge(hash)` and
    # `ActiveJob::Arguments.serialize` does not recurse into the result, so a `Date`,
    # `Time`, or `BigDecimal` left here would reach the queue adapter raw -- where a
    # JSON-native adapter rejects the job and a JSON column stringifies it and loses
    # precision. The per-type `serialize` contract is what guarantees it, and
    # `event.data` is already the whole payload in that form.
    #
    # FORMAT_VERSION governs the structure of this hash and nothing else. It is
    # deliberately independent of an event's schema version, and it does not govern the
    # canonical encoding of individual values -- that encoding is shared with the public
    # envelope and evolves as a public compatibility contract, not as a private format
    # bump.
    #
    # Evolving it is a staged, read-before-write deployment: a release that reads both
    # the old and the new format ships everywhere first, a later release starts writing
    # the new one, and the old reader is removed only once every queued old-format
    # message is drained or expired.
    class EventSerializer < ActiveJob::Serializers::ObjectSerializer
      FORMAT_VERSION = 1
      SUPPORTED_FORMAT_VERSIONS = [ FORMAT_VERSION ].freeze

      FORMAT_KEY = "format"
      TYPE_KEY = "event_type"
      VERSION_KEY = "event_version"
      METADATA_KEY = "metadata"
      DATA_KEY = "data"

      ID = "id"
      SOURCE = "source"
      OCCURRED_AT = "occurred_at"
      CORRELATION_ID = "correlation_id"
      CAUSATION_ID = "causation_id"
      EXTENSIONS = "extensions"

      # Every Event subclass, so applications register nothing.
      def klass
        EventRail::Event
      end

      # Read through methods rather than the constants directly, so a staged release can
      # subclass this to widen what it reads before anything writes the newer form. The
      # staging fixtures rely on that, and so would a real format migration.
      def format_version
        FORMAT_VERSION
      end

      def supported_format_versions
        SUPPORTED_FORMAT_VERSIONS
      end

      def serialize(event)
        unless event.stamped?
          raise InvalidEvent,
            "#{event.class} has not been published, so it cannot be enqueued; pass the event EventRail.publish " \
            "returned rather than the proposal"
        end

        super(
          FORMAT_KEY => format_version,
          TYPE_KEY => event.event_type,
          VERSION_KEY => event.version,
          METADATA_KEY => {
            ID => event.id,
            SOURCE => event.source,
            OCCURRED_AT => Timestamp.written(event.occurred_at),
            CORRELATION_ID => event.correlation_id,
            CAUSATION_ID => event.causation_id,
            EXTENSIONS => event.extensions
          },
          DATA_KEY => event.data
        )
      end

      def deserialize(hash)
        written_format = hash[FORMAT_KEY]
        unless supported_format_versions.include?(written_format)
          raise UnsupportedFormatError.new(
            format_version: written_format, supported_format_versions: supported_format_versions
          )
        end

        event_type = hash[TYPE_KEY]
        version = hash[VERSION_KEY]
        event_class = resolve!(event_type, version)

        payload = Notifications.payload_for_representation(hash).merge(format_version: written_format)

        ActiveSupport::Notifications.instrument("deserialize.event_rail", payload) do
          event_class.send(:__reconstruct__, data: read_data(hash), metadata: read_metadata(hash))
        end
      end

      private
        # Resolved through the prepared registry, never by constantizing the type name.
        # An unknown type and an unregistered version are different operational problems:
        # the first says this worker does not know the contract at all, the second says it
        # knows it at other versions and a producer is ahead of or behind this deploy.
        def resolve!(event_type, version)
          snapshot = Registry.snapshot
          event_class = snapshot.event_class_for(event_type, version)
          return event_class if event_class

          known_versions = snapshot.versions_of(event_type)
          if known_versions.empty?
            raise UnknownEventTypeError.new(event_type: event_type, version: version)
          end

          raise UnsupportedEventVersionError.new(
            event_type: event_type, version: version, supported_versions: known_versions
          )
        end

        def read_metadata(hash)
          metadata = hash[METADATA_KEY]
          unless metadata.is_a?(Hash)
            raise SerializationError, "malformed EventRail representation: metadata must be a hash"
          end

          Metadata.complete(
            id: metadata[ID],
            source: metadata[SOURCE],
            occurred_at: metadata[OCCURRED_AT],
            correlation_id: metadata[CORRELATION_ID],
            causation_id: metadata[CAUSATION_ID],
            extensions: metadata[EXTENSIONS] || {}
          )
        end

        def read_data(hash)
          data = hash[DATA_KEY]
          unless data.is_a?(Hash)
            raise SerializationError, "malformed EventRail representation: data must be a hash"
          end

          data
        end
    end
  end
end
