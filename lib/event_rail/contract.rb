module EventRail
  # The durable identity of an event schema: a stable type and an integer compatibility
  # version, independent of any Ruby class name. Constants may move; this does not.
  class Contract
    attr_reader :event_type, :version

    def self.of(event_class)
      new(event_type: event_class.event_type, version: event_class.version)
    end

    def initialize(event_type:, version:)
      unless event_type.is_a?(String) && !event_type.empty? && event_type.valid_encoding?
        raise InvalidContract, "event_type must be a non-empty valid string; got #{event_type.inspect}"
      end
      if event_type.bytesize > Limits::MAX_EVENT_TYPE_BYTES
        raise InvalidContract, "event_type exceeds #{Limits::MAX_EVENT_TYPE_BYTES} bytes"
      end
      unless version.is_a?(Integer) && version.positive?
        raise InvalidContract, "version must be a positive integer; got #{version.inspect}"
      end

      @event_type = event_type.dup.freeze
      @version = version
      freeze
    end

    def ==(other)
      other.instance_of?(self.class) && other.event_type == event_type && other.version == version
    end
    alias_method :eql?, :==

    def hash
      [ self.class, event_type, version ].hash
    end

    def to_s
      "#{event_type}/#{version}"
    end

    def inspect
      "#<EventRail::Contract #{self}>"
    end
  end
end
