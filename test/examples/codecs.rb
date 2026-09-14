require "json"

# Codecs an application owns.
#
# None of this ships in the gem. It exists to prove that two deliberately different wire
# representations can be built from `EventRail::Envelope`'s public readers alone -- no
# private event state, no knowledge of the Active Job representation, and no transport
# adapter inside EventRail. An application that needs Kafka, SQS, or HTTP writes something
# like this and owns every byte of it.
module ExampleCodecs
  # A CloudEvents-shaped JSON representation: EventRail's logical fields mapped onto
  # somebody else's field names, which is exactly the mapping the gem refuses to make on
  # an application's behalf.
  module CloudEventsJson
    SPEC_VERSION = "1.0"
    EXTENSION_PREFIX = "x"

    module_function

    def encode(envelope)
      document = {
        "specversion" => SPEC_VERSION,
        "type" => envelope.event_type,
        "dataschemaversion" => envelope.version,
        "id" => envelope.id,
        "source" => envelope.source,
        "time" => envelope.occurred_at.iso8601(6),
        "datacontenttype" => "application/json",
        "data" => envelope.data,
        "correlationid" => envelope.correlation_id
      }
      document["causationid"] = envelope.causation_id if envelope.causation_id
      envelope.extensions.each { |key, value| document["#{EXTENSION_PREFIX}#{key}"] = value }

      JSON.generate(document)
    end

    def decode(payload)
      document = JSON.parse(payload)
      raise ArgumentError, "unsupported CloudEvents version" unless document["specversion"] == SPEC_VERSION

      extensions = document.filter_map do |key, value|
        [ key.delete_prefix(EXTENSION_PREFIX), value ] if key.start_with?(EXTENSION_PREFIX)
      end.to_h

      EventRail::Envelope.new(
        contract: EventRail::Contract.new(
          event_type: document.fetch("type"), version: document.fetch("dataschemaversion")
        ),
        metadata: EventRail::Metadata.complete(
          id: document.fetch("id"),
          source: document.fetch("source"),
          occurred_at: document.fetch("time"),
          correlation_id: document.fetch("correlationid"),
          causation_id: document["causationid"],
          extensions: extensions
        ),
        data: document.fetch("data")
      )
    end
  end

  # A Protobuf-shaped representation: positional, length-delimited binary fields instead
  # of named JSON keys. It is deliberately nothing like the JSON codec, and it reads the
  # same envelope. Real Protobuf would use a generated message class; the point here is
  # that the representation is the application's choice and EventRail produces no bytes of
  # its own.
  module PackedBinary
    FIELDS = %i[event_type version id source occurred_at correlation_id causation_id data].freeze

    module_function

    def encode(envelope)
      pack(
        envelope.event_type,
        envelope.version.to_s,
        envelope.id,
        envelope.source,
        envelope.occurred_at.iso8601(6),
        envelope.correlation_id,
        envelope.causation_id.to_s,
        JSON.generate(envelope.data),
        JSON.generate(envelope.extensions)
      )
    end

    def decode(bytes)
      event_type, version, id, source, occurred_at, correlation_id, causation_id, data, extensions =
        unpack(bytes)

      EventRail::Envelope.new(
        contract: EventRail::Contract.new(event_type: event_type, version: Integer(version)),
        metadata: EventRail::Metadata.complete(
          id: id,
          source: source,
          occurred_at: occurred_at,
          correlation_id: correlation_id,
          causation_id: causation_id.empty? ? nil : causation_id,
          extensions: JSON.parse(extensions)
        ),
        data: JSON.parse(data)
      )
    end

    def pack(*values)
      values.map { |value| [ value.bytesize ].pack("N") + value.b }.join.b
    end

    def unpack(bytes)
      offset = 0
      values = []

      while offset < bytes.bytesize
        length = bytes.byteslice(offset, 4).unpack1("N")
        offset += 4
        values << bytes.byteslice(offset, length).force_encoding(Encoding::UTF_8)
        offset += length
      end

      values
    end
  end
end
