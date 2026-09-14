require "test_helper"
require "json"

Registry.reopen do
  module SerializationFixtures
    class Address < EventRail::Data
      attribute :city, :string
      attribute :postcode, :string
    end

    class Placed < EventRail::Event
      event_type "tests.serialization_placed"
      version 1
      default_source "acme.orders"

      attribute :order_id, :string
      attribute :total, :decimal
      attribute :placed_on, :date
      attribute :placed_at, :datetime
      attribute :gift, :boolean
      attribute :tags, :string, array: true
      attribute :properties
      attribute :address, Address
      identity_by :order_id
    end

    class PlacedV2 < EventRail::Event
      event_type "tests.serialization_placed"
      version 2
      default_source "acme.orders"

      attribute :order_id, :string
      identity_by :order_id
    end

    class Base < ActiveJob::Base
      include EventRail::JobContext
    end

    class OnPlaced < Base
      subscribes_to Placed

      class << self
        attr_accessor :received
      end
      self.received = []

      def perform(event)
        self.class.received << event
      end
    end
  end
end

Registry.prepare

class SerializationTest < ActiveSupport::TestCase
  Serializer = EventRailInternal::EventSerializer

  INPUT = {
    order_id: "o-1",
    total: "12.50",
    placed_on: "2026-09-01",
    placed_at: "2026-09-01T10:30:00.123456+02:00",
    gift: true,
    tags: [ "priority" ],
    properties: { "shipping" => { "methods" => [ "ground", nil, 2, 1.5 ] } },
    address: { city: "Berlin", postcode: "10115" }
  }.freeze

  setup do
    EventRail::Current.reset
    SerializationFixtures::OnPlaced.received = []
  end

  teardown { EventRail::Current.reset }

  # --- 7.1 the public envelope ---------------------------------------------------

  test "an envelope exposes contract, metadata, and the portable projection" do
    event = published
    envelope = EventRail::Envelope.of(event)

    assert_equal "tests.serialization_placed", envelope.event_type
    assert_equal 1, envelope.version
    assert_equal event.id, envelope.id
    assert_equal "acme.orders", envelope.source
    assert_equal event.occurred_at, envelope.occurred_at
    assert_equal event.correlation_id, envelope.correlation_id
    assert_equal event.data, envelope.data
  end

  test "envelope data contains no language-specific value for a codec to canonicalize" do
    envelope = EventRail::Envelope.of(published)

    assert_equal envelope.data, JSON.parse(JSON.generate(envelope.data))
    assert_equal "12.5", envelope.data.fetch("total")
    assert_equal "2026-09-01", envelope.data.fetch("placed_on")
    assert_equal({ "city" => "Berlin", "postcode" => "10115" }, envelope.data.fetch("address"))
  end

  test "an envelope produces no bytes and no universal hash" do
    envelope = EventRail::Envelope.of(published)

    # `to_json` is on every object once Active Support loads, so it is not evidence
    # either way. What matters is that EventRail defines no canonical hash, no byte
    # encoding, and no content type.
    refute_respond_to envelope, :to_h
    refute_respond_to envelope, :to_bytes
    refute_respond_to envelope, :encode
    refute_respond_to envelope, :content_type
  end

  test "an unpublished proposal has no envelope" do
    assert_raises(EventRail::InvalidEnvelope) do
      EventRail::Envelope.of(SerializationFixtures::Placed.new(**INPUT))
    end
  end

  test "a codec can round-trip an event through the public readers alone" do
    event = published
    envelope = EventRail::Envelope.of(event)

    # What any user-owned codec does: read the public fields, write them somewhere, read
    # them back, rebuild the envelope. JSON stands in for Protobuf or CloudEvents here.
    wire = JSON.generate(
      "type" => envelope.event_type,
      "version" => envelope.version,
      "id" => envelope.id,
      "source" => envelope.source,
      "time" => envelope.occurred_at.iso8601(6),
      "correlation" => envelope.correlation_id,
      "causation" => envelope.causation_id,
      "extensions" => envelope.extensions,
      "data" => envelope.data
    )

    decoded = JSON.parse(wire)
    rebuilt = EventRail::Envelope.new(
      contract: EventRail::Contract.new(event_type: decoded.fetch("type"), version: decoded.fetch("version")),
      metadata: EventRail::Metadata.complete(
        id: decoded.fetch("id"),
        source: decoded.fetch("source"),
        occurred_at: decoded.fetch("time"),
        correlation_id: decoded.fetch("correlation"),
        causation_id: decoded.fetch("causation"),
        extensions: decoded.fetch("extensions")
      ),
      data: decoded.fetch("data")
    )

    assert_equal envelope, rebuilt
    assert_equal event, rebuilt.to_event(SerializationFixtures::Placed)
  end

  test "an envelope preserves a field the local class does not declare" do
    envelope = EventRail::Envelope.new(
      contract: EventRail::Contract.new(event_type: "tests.serialization_placed", version: 1),
      metadata: external_metadata,
      data: minimal_data.merge("loyalty_tier" => "gold")
    )

    event = envelope.to_event(SerializationFixtures::Placed)

    refute_respond_to event, :loyalty_tier
    assert_equal "gold", event.data.fetch("loyalty_tier")
    assert_equal "gold", EventRail::Envelope.of(event).data.fetch("loyalty_tier")
  end

  # --- 7.2 validated reconstruction through an explicit class --------------------

  test "reconstruction refuses a class that does not match the envelope contract" do
    envelope = EventRail::Envelope.new(
      contract: EventRail::Contract.new(event_type: "tests.serialization_placed", version: 1),
      metadata: external_metadata,
      data: minimal_data
    )

    assert_raises(EventRail::InvalidEnvelope) { envelope.to_event(SerializationFixtures::PlacedV2) }
  end

  test "reconstruction never constantizes a name from the envelope" do
    envelope = EventRail::Envelope.new(
      contract: EventRail::Contract.new(event_type: "tests.serialization_placed", version: 1),
      metadata: external_metadata,
      data: minimal_data
    )

    [ "SerializationFixtures::Placed", :Placed, Object, nil ].each do |candidate|
      assert_raises(EventRail::InvalidEnvelope, "#{candidate.inspect} must be refused") do
        envelope.to_event(candidate)
      end
    end
  end

  test "an envelope refuses a malformed contract, metadata, or data" do
    assert_raises(EventRail::InvalidContract) { EventRail::Contract.new(event_type: "", version: 1) }
    assert_raises(EventRail::InvalidContract) { EventRail::Contract.new(event_type: "x", version: 0) }
    assert_raises(EventRail::InvalidMetadata) do
      EventRail::Metadata.complete(id: "i", source: nil, occurred_at: Time.now.utc, correlation_id: "c")
    end
    assert_raises(EventRail::InvalidMetadata) do
      EventRail::Metadata.complete(
        id: "i", source: "s", occurred_at: Time.now.utc, correlation_id: "c", extensions: { "traceparent" => "x" }
      )
    end
    assert_raises(EventRail::InvalidEnvelope) do
      EventRail::Envelope.new(
        contract: EventRail::Contract.new(event_type: "t", version: 1), metadata: external_metadata, data: []
      )
    end
    assert_raises(EventRail::InvalidEnvelope) do
      EventRail::Envelope.new(
        contract: EventRail::Contract.new(event_type: "t", version: 1),
        metadata: EventRail::Metadata.proposed,
        data: {}
      )
    end
  end

  test "reconstruction refuses data whose nesting exceeds the documented depth" do
    deep = (EventRail::Limits::MAX_RAW_DEPTH + 2).times.reduce("leaf") { |inner, _| { "nested" => inner } }
    envelope = EventRail::Envelope.new(
      contract: EventRail::Contract.new(event_type: "tests.serialization_placed", version: 1),
      metadata: external_metadata,
      data: minimal_data.merge("properties" => deep)
    )

    assert_raises(EventRail::CastingError) { envelope.to_event(SerializationFixtures::Placed) }
  end

  test "the internal queue registry does not authorize external input" do
    refute_respond_to EventRail::Envelope, :resolve
    refute_respond_to EventRail, :event_class_for
    refute_respond_to EventRail, :registry
  end

  # --- 7.3 the private Active Job representation ---------------------------------

  test "an event survives a queue round trip as the same value" do
    event = published
    perform_enqueued_jobs

    received = SerializationFixtures::OnPlaced.received.sole

    assert_equal event, received
    assert_equal event.id, received.id
    assert_equal event.source, received.source
    assert_equal event.occurred_at, received.occurred_at
    assert_equal event.correlation_id, received.correlation_id
    assert_equal event.extensions, received.extensions
    assert_equal BigDecimal("12.5"), received.total
    assert_equal Date.new(2026, 9, 1), received.placed_on
    assert_instance_of SerializationFixtures::Address, received.address
  end

  test "the written representation is JSON-native and survives an encoding cycle" do
    written = Serializer.serialize(published)

    assert_equal written, JSON.parse(JSON.generate(written)),
      "Active Job does not recurse into a serializer's output, so anything non-JSON reaches the adapter raw"
    assert_equal 1, written.fetch("format")
    assert_equal "tests.serialization_placed", written.fetch("event_type")
    assert_equal "12.5", written.fetch("data").fetch("total")
  end

  test "everything EventRail puts in an enqueued job payload is JSON-native" do
    published
    # The test adapter adds symbol-keyed conveniences of its own; what EventRail
    # contributes is the serialized argument and the context entry.
    payload = enqueued_jobs.sole.slice("arguments", EventRail::JobContext::ENTRY_KEY)

    assert_equal payload, JSON.parse(JSON.generate(payload)),
      "an adapter that accepts only JSON-native argument values must accept this enqueue"
  end

  test "the format version is independent of the event schema version" do
    written = Serializer.serialize(published)

    assert_equal 1, written.fetch("format")
    assert_equal 1, written.fetch("event_version")
    refute_equal Serializer::FORMAT_KEY, Serializer::VERSION_KEY
  end

  test "an unpublished proposal cannot be enqueued" do
    error = assert_raises(EventRail::InvalidEvent) do
      Serializer.serialize(SerializationFixtures::Placed.new(**INPUT))
    end

    assert_match(/EventRail.publish/, error.message)
  end

  test "a format version this release cannot read raises before subscriber code runs" do
    written = Serializer.serialize(published).merge("format" => 99)

    error = assert_raises(EventRail::UnsupportedFormatError) { Serializer.deserialize(written) }

    assert_equal 99, error.format_version
    assert_equal [ 1 ], error.supported_format_versions
  end

  test "an unregistered event type raises without resolving a constant" do
    written = Serializer.serialize(published).merge("event_type" => "not.registered")

    error = assert_raises(EventRail::UnknownEventTypeError) { Serializer.deserialize(written) }

    assert_equal "not.registered", error.event_type
  end

  test "a registered type at an unregistered version raises its own error" do
    written = Serializer.serialize(published).merge("event_version" => 99)

    error = assert_raises(EventRail::UnsupportedEventVersionError) { Serializer.deserialize(written) }

    assert_equal "tests.serialization_placed", error.event_type
    assert_equal 99, error.version
    assert_equal [ 1, 2 ], error.supported_versions.sort
  end

  test "a malformed representation raises a serialization error" do
    written = Serializer.serialize(published)

    assert_raises(EventRail::SerializationError) { Serializer.deserialize(written.merge("data" => "nope")) }
    assert_raises(EventRail::SerializationError) { Serializer.deserialize(written.merge("metadata" => nil)) }
  end

  test "an unknown field inside nested data survives the queue" do
    envelope = EventRail::Envelope.new(
      contract: EventRail::Contract.new(event_type: "tests.serialization_placed", version: 1),
      metadata: external_metadata,
      data: minimal_data.merge("address" => { "city" => "Berlin", "what3words" => "index.home.raft" })
    )
    event = envelope.to_event(SerializationFixtures::Placed)

    restored = Serializer.deserialize(Serializer.serialize(event))

    assert_equal "index.home.raft", restored.address.data.fetch("what3words")
    assert_equal event, restored
  end

  # Task 2.18's remaining assertion: `assert_enqueued_with(args:)` compares serialized
  # arguments, so it only matches when the written form of one logical payload is
  # identical between the expectation and the queue -- which is what the deterministic
  # projection and value equality together buy.
  test "assert_enqueued_with matches a published event through a queue round trip" do
    event = published

    assert_enqueued_with(job: SerializationFixtures::OnPlaced, args: [ event ])
  end

  test "a reconstructed event equals the one it was written from" do
    event = published

    assert_equal event, Serializer.deserialize(Serializer.serialize(event))
    assert_equal event.hash, Serializer.deserialize(Serializer.serialize(event)).hash
  end

  test "deserialization emits a notification carrying the format version" do
    written = Serializer.serialize(published)
    payloads = []
    subscription = ActiveSupport::Notifications.subscribe("deserialize.event_rail") do |*args|
      payloads << ActiveSupport::Notifications::Event.new(*args).payload
    end

    Serializer.deserialize(written)

    assert_equal 1, payloads.sole.fetch(:format_version)
    assert_equal "tests.serialization_placed", payloads.sole.fetch(:event_type)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  private
    def published
      EventRail.publish(SerializationFixtures::Placed.new(**INPUT, extensions: { "tenant" => "acme" })).event
    end

    def external_metadata
      EventRail::Metadata.complete(
        id: "ext-1",
        source: "partner.orders",
        occurred_at: Time.utc(2026, 8, 1),
        correlation_id: "ext-corr",
        extensions: { "region" => "eu" }
      )
    end

    def minimal_data
      { "order_id" => "o-1" }
    end
end
