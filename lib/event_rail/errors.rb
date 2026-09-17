module EventRail
  # Every error EventRail raises descends from this, so an application can rescue
  # the library without naming its internals. Each subclass exposes stable
  # diagnostic fields only -- contracts, identifiers, and application classes --
  # never a registry, serializer, job instance, or other internal object, and each
  # preserves the cause it wrapped so the original backtrace stays reachable.
  class Error < StandardError
  end

  # Something about a class body is wrong, so it is wrong for every instance: a
  # reserved or shadowing attribute name, a callable default, an attribute type with
  # no written form, an invalid subscription.
  class DeclarationError < Error
  end

  # An application's own configuration is wrong: a discovery root that is not an autoload
  # root of the application or any engine. Distinct from a declaration fault, which is about
  # a class body, and raised at preparation so it fails the boot that introduced it.
  class ConfigurationError < Error
  end

  # A value cannot become the declared type without discarding information, or is not
  # portable at all.
  class CastingError < Error
  end

  class InvalidData < Error
    attr_reader :validation_errors

    def initialize(message = "nested data is invalid", validation_errors: {})
      @validation_errors = validation_errors.freeze
      super(message)
    end
  end

  class InvalidEvent < Error
    attr_reader :validation_errors

    def initialize(message = "event is invalid", validation_errors: {})
      @validation_errors = validation_errors.freeze
      super(message)
    end
  end

  class InvalidMetadata < Error
  end

  class InvalidContract < Error
  end

  class DuplicateContractError < InvalidContract
    attr_reader :event_type, :version, :event_classes

    def initialize(event_type:, version:, event_classes:)
      @event_type = event_type
      @version = version
      @event_classes = event_classes.freeze
      names = event_classes.map { |event_class| event_class.name || event_class.inspect }
      super("duplicate event contract #{event_type.inspect} version #{version}: #{names.join(", ")}")
    end
  end

  # A logical context cannot be established: a nested scope tried to replace lineage
  # it inherited, or an identifier or extension is out of bounds.
  class InvalidContext < Error
  end

  # An external envelope cannot be trusted into a typed event.
  class InvalidEnvelope < Error
  end

  # Publication ran before the application finished preparing, so the subscriber
  # snapshot does not exist yet. Deliberately distinct from a prepared application
  # whose event happens to have no subscribers.
  class NotReadyError < Error
  end

  # A subscriber was handed an argument it cannot treat as its declared event.
  class UnexpectedEventError < Error
    attr_reader :job_class, :expected_event_classes, :received_class

    def initialize(message, job_class:, expected_event_classes:, received_class:)
      @job_class = job_class
      @expected_event_classes = expected_event_classes.freeze
      @received_class = received_class
      super(message)
    end
  end

  class SerializationError < Error
  end

  # The representation names a format this release does not read. Raised before any
  # subscriber code runs, and distinct from an event schema version problem: the
  # format version governs the representation's structure, not the event's contract.
  class UnsupportedFormatError < SerializationError
    attr_reader :format_version, :supported_format_versions

    def initialize(format_version:, supported_format_versions:)
      @format_version = format_version
      @supported_format_versions = supported_format_versions.freeze
      super(
        "unsupported EventRail serialization format #{format_version.inspect}; " \
        "this release reads #{supported_format_versions.join(", ")}"
      )
    end
  end

  class UnknownEventTypeError < SerializationError
    attr_reader :event_type, :version

    def initialize(event_type:, version:)
      @event_type = event_type
      @version = version
      super("no registered event class for #{event_type.inspect} version #{version.inspect}")
    end
  end

  class UnsupportedEventVersionError < SerializationError
    attr_reader :event_type, :version, :supported_versions

    def initialize(event_type:, version:, supported_versions:)
      @event_type = event_type
      @version = version
      @supported_versions = supported_versions.freeze
      super(
        "event #{event_type.inspect} version #{version.inspect} is not registered; " \
        "registered versions are #{supported_versions.sort.join(", ")}"
      )
    end
  end

  class PublicationError < Error
  end

  # The same logical fact was published twice in one execution after the first
  # publication succeeded.
  class DuplicatePublicationError < PublicationError
    attr_reader :event_type, :version, :event_id

    def initialize(event_type:, version:, event_id:)
      @event_type = event_type
      @version = version
      @event_id = event_id
      super(
        "#{event_type.inspect} version #{version} with this logical identity was already published " \
        "as #{event_id.inspect} in this execution"
      )
    end
  end

  # A retry resolved to a recorded failed publication whose fact differs from the one
  # now being published. Neither choice is safe -- fanning out the recorded payload
  # discards the new data, and reusing the recorded ID for new data lies to every
  # consumer that deduplicates on it -- so publication refuses instead.
  class RetryPayloadMismatchError < PublicationError
    attr_reader :event_type, :version, :event_id, :differing_fields

    def initialize(event_type:, version:, event_id:, differing_fields:)
      @event_type = event_type
      @version = version
      @event_id = event_id
      @differing_fields = differing_fields.freeze
      super(
        "retrying publication of #{event_type.inspect} version #{version} as #{event_id.inspect} " \
        "but #{differing_fields.sort.join(", ")} differ from the recorded event"
      )
    end
  end

  # Publication happened inside an open application database transaction. Both queue
  # deferral settings are wrong there, in opposite directions: a deferred enqueue
  # cannot report its own failure, and an immediate one announces a fact a rollback
  # then contradicts.
  class TransactionalPublicationError < PublicationError
    def initialize(message = nil)
      super(
        message ||
          "cannot publish inside an open database transaction; publish after the transaction commits"
      )
    end
  end

  # Fanout could not complete. The accepted and skipped lists are what an operator
  # needs to know which subscribers may already have work queued, because publication
  # is at-least-once and the retry will enqueue all of them again.
  class EnqueueError < PublicationError
    attr_reader :event, :accepted_subscribers, :skipped_subscribers, :failed_subscriber

    def initialize(event:, accepted_subscribers:, skipped_subscribers:, failed_subscriber:, message: nil)
      @event = event
      @accepted_subscribers = accepted_subscribers.freeze
      @skipped_subscribers = skipped_subscribers.freeze
      @failed_subscriber = failed_subscriber
      super(
        message ||
          "could not enqueue #{failed_subscriber} for #{event.event_type.inspect} version #{event.version} " \
          "(#{event.id}); #{accepted_subscribers.length} accepted, #{skipped_subscribers.length} skipped"
      )
    end
  end
end
