module EventRail
  class Error < StandardError
  end

  class DeclarationError < Error
  end

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
end
