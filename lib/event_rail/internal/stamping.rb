require "securerandom"

module EventRail
  module Internal
    # Turns a proposal into a stamped fact: resolves source, selects logical identity,
    # derives its ID, fixes occurrence time, and installs lineage. Fanout
    # is a separate concern layered on top of this.
    module Stamping
      module_function

      Prepared = Struct.new(:event, :execution, :logical_key, :relayed, keyword_init: true) do
        def relayed?
          relayed
        end
      end

      def prepare(event, identity: nil, source: nil)
        unless event.is_a?(Event)
          raise InvalidEvent, "#{event.inspect} is not an EventRail::Event"
        end
        Metadata.validate_source!(source) unless source.nil?

        return relay(event, identity: identity, source: source) if event.stamped?

        validate_identity!(event, identity)
        source = (source || event.class.default_source)&.dup&.freeze
        raise InvalidMetadata, "source is required to publish #{event.class}" unless source

        execution = Execution.current
        derived_id = derive_id(event, execution, source, declared_identity(event, identity))
        logical_key = record_key(source, event, derived_id)

        recorded = execution&.derives_identity? ? execution.record(logical_key) : nil
        if recorded&.succeeded?
          raise DuplicatePublicationError.new(
            event_type: event.event_type, version: event.version, event_id: recorded.event.id
          )
        end

        extensions = Extensions.merge!(Current.extensions, event.extensions, error: InvalidEvent)
        detect_retry_mismatch!(event, recorded, extensions) if recorded

        event_id = recorded&.event&.id || derived_id
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

      # A relayed fact belongs to its origin. Its ID, source, occurrence time, lineage
      # -- an absent causation included -- and extensions are preserved, and the relaying
      # application's own context is deliberately not merged in: local baggage is not
      # part of somebody else's event. Two producers may use the same ID, so the source is
      # part of what makes a relay a repetition, and a relay retried with a different
      # payload is refused exactly as a local publication is.
      def relay(event, identity:, source:)
        unless identity.nil?
          raise PublicationError,
            "#{event.event_type.inspect} already carries the event ID #{event.id.inspect}, so a publication " \
            "identity cannot apply to it"
        end
        if source && source != event.source
          raise InvalidMetadata,
            "#{event.event_type.inspect} #{event.id.inspect} already comes from #{event.source.inspect}; " \
            "publishing it as #{source.inspect} would re-attribute somebody else's fact"
        end

        execution = Execution.current
        logical_key = record_key(event.source, event, event.id)

        if execution&.derives_identity?
          recorded = execution.record(logical_key)
          if recorded&.succeeded?
            raise DuplicatePublicationError.new(
              event_type: event.event_type, version: event.version, event_id: event.id
            )
          end
          detect_retry_mismatch!(event, recorded, event.extensions) if recorded
          execution.record!(logical_key, event: event, succeeded: false)
        end

        Prepared.new(event: event, execution: execution, logical_key: logical_key, relayed: true)
      end
      private_class_method :relay

      # One record per published event, whether it was stamped here or arrives stamped:
      # so publishing the stamped result of a failed local publication is a retry of it,
      # and publishing it again after success is a duplicate. Frozen binary copies, so a
      # caller mutating the string it passed cannot move a record, and so a relayed ID is
      # compared as the opaque bytes it is, whatever they hold.
      def record_key(source, event, id)
        [ source.b.freeze, event.event_type, event.version, id.b.freeze ].freeze
      end
      private_class_method :record_key

      # The fact an event declares itself to be, as a list: an explicit publication
      # identity, or the class's declared identity attributes in declaration order. Nil
      # when it declares none. An explicit identity and a single declared attribute with
      # the same value name the same fact.
      def declared_identity(event, identity)
        return [ identity ] if identity

        declared = event.class.identity_by
        declared.empty? ? nil : declared.map { |name| event.public_send(name) }
      end
      private_class_method :declared_identity

      # A publication identity names a fact across every execution, so it is a string --
      # an integer at one call site and its decimal spelling at another would be two
      # facts -- and it cannot contradict an identity the class already declares.
      def validate_identity!(event, identity)
        return if identity.nil?

        unless event.class.identity_by.empty?
          raise PublicationError,
            "#{event.class} declares #{event.class.identity_by.join(", ")} as its identity, so a publication " \
            "identity cannot apply to it"
        end
        unless identity.is_a?(String) && !identity.empty? && identity.valid_encoding?
          raise PublicationError, "publication identity must be a non-empty string; got #{identity.inspect}"
        end
        if identity.bytesize > Limits::MAX_IDENTIFIER_BYTES
          raise PublicationError, "publication identity exceeds #{Limits::MAX_IDENTIFIER_BYTES} bytes"
        end
      end
      private_class_method :validate_identity!

      # A declared fact's ID depends on nothing but the fact. Without one, an ID derived
      # from the execution is stable across its retries and redeliveries; outside any
      # execution there is nothing stable to derive from, and the ID is random, in time
      # order so a downstream log indexes it well.
      def derive_id(event, execution, source, declared)
        if declared
          Identity.fact(source: source, event_type: event.event_type, identity: declared).freeze
        elsif execution&.derives_identity?
          Identity.execution(
            source: source, job_class: execution.job_class, scope: execution.scope,
            event_type: event.event_type, version: event.version
          ).freeze
        else
          SecureRandom.uuid_v7.freeze
        end
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
