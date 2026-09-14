require_relative "codecs"

# An inbound consumer and an outbound bridge an application owns.
#
# EventRail has no concept of internal versus external, no direction, no topic, and no
# transport marker. Everything below -- the allowlist, the export policy that stops loops,
# the acknowledgement rule -- is application policy, which is the point: those decisions
# depend on trust boundaries the gem cannot see.
module ExampleTransport
  # Only these contracts may enter from outside, and only as these classes. A type name
  # arriving over a network never names a Ruby constant.
  class Allowlist
    def initialize(entries)
      @entries = entries.freeze
    end

    def fetch(event_type, version)
      @entries.fetch([ event_type, version ]) do
        raise EventRail::InvalidEnvelope,
          "#{event_type.inspect} version #{version.inspect} is not accepted from outside this application"
      end
    end
  end

  # Decodes, validates against the allowlist, publishes internally, and acknowledges only
  # after publication succeeds. Failure leaves both the acknowledgement and the routing to
  # the transport layer, which is the only thing that knows about visibility timeouts,
  # dead-letter queues, and redrive.
  class InboundConsumer
    def initialize(allowlist:, codec: ExampleCodecs::CloudEventsJson)
      @allowlist = allowlist
      @codec = codec
    end

    def consume(message)
      envelope = @codec.decode(message.payload)
      event_class = @allowlist.fetch(envelope.event_type, envelope.version)

      # A relayed fact keeps its origin's identity, source, occurrence time, correlation,
      # and extensions; publication fills only a missing causation.
      EventRail.publish(envelope.to_event(event_class))

      message.ack
      true
    rescue EventRail::Error, JSON::ParserError, ArgumentError, KeyError
      # No ack: the transport decides whether this is retried or dead-lettered.
      false
    end
  end

  # Exports selected events outward. The export policy is what stops a loop: an event this
  # application did not produce is not re-exported, so a relayed event cannot bounce back
  # to the system it came from.
  class ExportPolicy
    def initialize(local_source:, exportable_types:)
      @local_source = local_source
      @exportable_types = exportable_types.freeze
    end

    def export?(event)
      event.source == @local_source && @exportable_types.include?(event.event_type)
    end
  end

  class OutboundBridge
    def initialize(policy:, codec: ExampleCodecs::CloudEventsJson, transport:)
      @policy = policy
      @codec = codec
      @transport = transport
    end

    def deliver(event)
      return :skipped unless @policy.export?(event)

      @transport.publish(@codec.encode(EventRail::Envelope.of(event)))
      :delivered
    end
  end

  Message = Struct.new(:payload, :acked, keyword_init: true) do
    def ack
      self.acked = true
    end

    def acked?
      acked == true
    end
  end

  class FakeTransport
    attr_reader :published

    def initialize
      @published = []
    end

    def publish(payload)
      @published << payload
    end
  end
end
