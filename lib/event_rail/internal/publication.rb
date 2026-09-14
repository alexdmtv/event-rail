require "securerandom"

module EventRail
  module Internal
    # Turns a proposal into a stamped fact: resolves source, selects logical identity,
    # derives a retry-stable ID, fixes occurrence time, and installs lineage. Fanout
    # is a separate concern layered on top of this.
    module Publication
      module_function

      Prepared = Struct.new(:event, :execution, :logical_key, :relayed, keyword_init: true) do
        def relayed?
          relayed
        end
      end

      def prepare(event, key: nil)
        unless event.is_a?(Event)
          raise InvalidEvent, "#{event.inspect} is not an EventRail::Event"
        end

        return relay(event, key: key) if event.stamped?

        validate_key!(key)
        execution = Execution.current
        logical_identity = resolve_logical_identity(event, key)
        logical_key = [ event.event_type, event.version, Identity.encode_component(logical_identity) ].freeze

        recorded = execution&.derives_identity? ? execution.record(logical_key) : nil
        if recorded&.succeeded?
          raise DuplicatePublicationError.new(
            event_type: event.event_type, version: event.version, event_id: recorded.event.id
          )
        end

        extensions = Extensions.merge!(Current.extensions, event.extensions, error: InvalidEvent)
        detect_retry_mismatch!(event, recorded, extensions) if recorded

        source = event.class.default_source
        event_id = recorded&.event&.id || derive_id(event, execution, source, logical_identity)
        occurred_at = event.occurred_at || recorded&.event&.occurred_at || default_occurred_at(execution)

        stamped = event.send(
          :__stamp__,
          id: event_id,
          source: source,
          occurred_at: occurred_at,
          correlation_id: Current.correlation_id || event_id,
          causation_id: Current.message_id,
          extensions: extensions
        )

        execution.record!(logical_key, event: stamped, succeeded: false) if execution&.derives_identity?

        Prepared.new(event: stamped, execution: execution, logical_key: logical_key, relayed: false)
      end

      def succeeded!(prepared)
        execution = prepared.execution
        return unless execution&.derives_identity?

        execution.record!(prepared.logical_key, event: prepared.event, succeeded: true)
      end

      # A relayed fact belongs to its origin. Its ID, source, occurrence time,
      # correlation, and extensions are preserved, and the relaying application's own
      # context extensions are deliberately not merged in: local baggage is not part of
      # somebody else's event. Only a missing causation is filled, because the local
      # message genuinely is what caused this relay.
      def relay(event, key:)
        unless key.nil?
          raise PublicationError,
            "#{event.event_type.inspect} already carries the event ID #{event.id.inspect}, so a publication " \
            "key cannot apply to it"
        end

        execution = Execution.current
        logical_key = [ event.event_type, event.version, Identity.encode_component(event.id) ].freeze

        if execution&.derives_identity?
          recorded = execution.record(logical_key)
          if recorded&.succeeded?
            raise DuplicatePublicationError.new(
              event_type: event.event_type, version: event.version, event_id: event.id
            )
          end
        end

        relayed = if event.causation_id.nil? && Current.message_id
          event.send(
            :__stamp__,
            id: event.id,
            source: event.source,
            occurred_at: event.occurred_at,
            correlation_id: event.correlation_id,
            causation_id: Current.message_id,
            extensions: event.extensions
          )
        else
          event
        end

        execution.record!(logical_key, event: relayed, succeeded: false) if execution&.derives_identity?

        Prepared.new(event: relayed, execution: execution, logical_key: logical_key, relayed: true)
      end
      private_class_method :relay

      # 1. An explicit event ID wins, which is the relay path above.
      # 2. An explicit call-site key.
      # 3. The event class's declared identity attributes.
      # 4. A singleton marker, for the first publication of that type in an execution.
      def resolve_logical_identity(event, key)
        return key if key

        declared = event.class.identity_by
        return Identity::SINGLETON if declared.empty?

        declared.map { |name| event.public_send(name) }
      end
      private_class_method :resolve_logical_identity

      # A key spelled as an integer at one call site and as its decimal string at
      # another would derive two identities for one fact, and nothing would report it.
      def validate_key!(key)
        return if key.nil?

        unless key.is_a?(String) && !key.empty? && key.valid_encoding?
          raise PublicationError, "publication key must be a non-empty string; got #{key.inspect}"
        end
        if key.bytesize > Limits::MAX_IDENTIFIER_BYTES
          raise PublicationError, "publication key exceeds #{Limits::MAX_IDENTIFIER_BYTES} bytes"
        end
      end
      private_class_method :validate_key!

      def derive_id(event, execution, source, logical_identity)
        return SecureRandom.uuid.freeze unless execution&.derives_identity?

        unless source
          raise InvalidMetadata, "source is required to publish #{event.class}"
        end

        Identity.derive(
          source: source,
          job_class: execution.job_class,
          scope: execution.scope,
          event_type: event.event_type,
          version: event.version,
          logical_identity: logical_identity
        ).freeze
      end
      private_class_method :derive_id

      # The logical publication time: this execution's start, so it is stable across
      # the attempt's own retries, and never inherited from a cause, so a follow-up
      # event is never timestamped earlier than the work that produced it.
      def default_occurred_at(execution)
        execution&.started_at || Timestamp.normalize(Time.now.utc, field: "occurred_at")
      end
      private_class_method :default_occurred_at

      # Retrying a failed publication republishes the same fact, not merely the same
      # identity. Choosing silently between the recorded payload and the new one would
      # either discard data or hand new data an ID consumers already deduplicated on.
      def detect_retry_mismatch!(event, recorded, extensions)
        differing = []
        differing << "payload" unless event.data == recorded.event.data
        if event.occurred_at && event.occurred_at != recorded.event.occurred_at
          differing << "occurred_at"
        end
        differing << "extensions" unless extensions == recorded.event.extensions
        return if differing.empty?

        raise RetryPayloadMismatchError.new(
          event_type: event.event_type,
          version: event.version,
          event_id: recorded.event.id,
          differing_fields: differing
        )
      end
      private_class_method :detect_retry_mismatch!
    end
  end
end
