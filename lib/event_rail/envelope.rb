module EventRail
  # The format-neutral boundary an application's own codec reads and writes.
  #
  #   envelope = EventRail::Envelope.of(published.event)
  #   payload  = MyJsonCodec.encode(envelope)   # the application owns the bytes
  #
  # EventRail produces no bytes and mandates no format. It exposes the logical fields --
  # contract, metadata, and the event's portable data projection -- and stops there,
  # because canonical bytes, a universal hash, and a content type are decisions that
  # belong to whoever owns the transport. There is deliberately no `to_h` that could
  # become a de facto wire format.
  #
  # `data` is the portable projection, so a codec never receives a `Date`, a
  # `BigDecimal`, or a nested Ruby object it would have to decide how to canonicalize.
  # Every value is a JSON primitive, array, or string-keyed hash, including fields a
  # newer producer added that the local class does not declare.
  class Envelope
    attr_reader :contract, :metadata, :data

    def self.of(event)
      unless event.is_a?(Event)
        raise InvalidEnvelope, "#{event.inspect} is not an EventRail::Event"
      end
      unless event.stamped?
        raise InvalidEnvelope, "#{event.class} has not been published, so it has no durable metadata to export"
      end

      new(contract: Contract.of(event.class), metadata: event.metadata, data: event.data)
    end

    def initialize(contract:, metadata:, data:)
      unless contract.is_a?(Contract)
        raise InvalidEnvelope, "contract must be an EventRail::Contract; got #{contract.inspect}"
      end
      unless metadata.is_a?(Metadata) && metadata.complete?
        raise InvalidEnvelope, "metadata must be complete EventRail::Metadata; got #{metadata.inspect}"
      end
      unless data.is_a?(Hash) && data.keys.all? { |key| key.is_a?(String) }
        raise InvalidEnvelope, "data must be a string-keyed hash"
      end

      @contract = contract
      @metadata = metadata
      @data = data.freeze
      freeze
    end

    def event_type
      contract.event_type
    end

    def version
      contract.version
    end

    def id
      metadata.id
    end

    def source
      metadata.source
    end

    def occurred_at
      metadata.occurred_at
    end

    def correlation_id
      metadata.correlation_id
    end

    def causation_id
      metadata.causation_id
    end

    def extensions
      metadata.extensions
    end

    # The only public trusted-reconstruction entry point, and it takes the class
    # explicitly.
    #
    # V1 defines no resolver protocol and never constantizes anything from the
    # envelope: a type name arriving over a network must not be able to name a Ruby
    # constant. An application maps a contract to a class with its own allowlist before
    # calling this:
    #
    #   ALLOWED = { [ "orders.order_placed", 1 ] => Orders::OrderPlaced }.freeze
    #   event_class = ALLOWED.fetch([ envelope.event_type, envelope.version ])
    #   envelope.to_event(event_class)
    #
    # The internal queue registry deliberately does not authorize external input: it
    # exists so a worker can read its own organization's queue, which is a different
    # trust question from accepting a message off a shared bus.
    def to_event(event_class)
      unless event_class.is_a?(Class) && event_class < Event
        raise InvalidEnvelope, "#{event_class.inspect} is not an EventRail::Event class"
      end
      unless event_class.event_type == event_type && event_class.version == version
        raise InvalidEnvelope,
          "#{event_class} declares #{Contract.of(event_class)} but this envelope carries #{contract}"
      end

      event_class.send(:__reconstruct__, data: data, metadata: metadata)
    end

    def ==(other)
      other.instance_of?(self.class) && other.contract == contract &&
        other.metadata == metadata && other.data == data
    end
    alias_method :eql?, :==

    def hash
      [ self.class, contract, metadata, data ].hash
    end

    # Contract and identity only: an envelope carries domain data, and a diagnostic
    # string is not the place for it.
    def inspect
      "#<EventRail::Envelope #{contract} id=#{id.inspect} source=#{source.inspect}>"
    end
  end
end
