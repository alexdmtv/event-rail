require "test_helper"
require_relative "../examples/transport"

Registry.reopen do
  module BoundaryFixtures
    class Line < EventRail::Data
      attribute :sku, :string
      attribute :quantity, :integer
    end

    class Placed < EventRail::Event
      event_type "tests.boundary_placed"
      version 1
      default_source "acme.orders"

      attribute :order_id, :string
      attribute :total, :decimal
      attribute :placed_on, :date
      attribute :placed_at, :datetime
      attribute :gift, :boolean
      attribute :properties
      attribute :lines, Line, array: true
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

class ExternalBoundaryTest < ActiveSupport::TestCase
  INPUT = {
    order_id: "o-1",
    total: "12.50",
    placed_on: "2026-09-01",
    placed_at: "2026-09-01T10:30:00.123456+02:00",
    gift: true,
    properties: { "channel" => { "name" => "web", "weights" => [ 1, 2.5, nil ] } },
    lines: [ { sku: "a", quantity: 1 }, { sku: "b", quantity: 2 } ]
  }.freeze

  ALLOWLIST = ExampleTransport::Allowlist.new(
    [ "tests.boundary_placed", 1 ] => BoundaryFixtures::Placed
  )

  setup do
    EventRail::Current.reset
    BoundaryFixtures::OnPlaced.received = []
  end

  teardown { EventRail::Current.reset }

  # --- 7.5 user-owned codecs over the public envelope ----------------------------

  test "a JSON CloudEvents-style codec preserves every logical field" do
    assert_round_trips ExampleCodecs::CloudEventsJson
  end

  test "a deliberately different binary codec preserves every logical field" do
    assert_round_trips ExampleCodecs::PackedBinary
  end

  test "the two codecs produce entirely different representations of one event" do
    envelope = EventRail::Envelope.of(published)

    json = ExampleCodecs::CloudEventsJson.encode(envelope)
    packed = ExampleCodecs::PackedBinary.encode(envelope)

    refute_equal json, packed
    assert_equal Encoding::BINARY, packed.encoding
    assert_includes json, "specversion"
    refute_includes packed, "specversion"
    assert_equal envelope, ExampleCodecs::CloudEventsJson.decode(json)
    assert_equal envelope, ExampleCodecs::PackedBinary.decode(packed)
  end

  test "a codec needs no private event state and no knowledge of the queue format" do
    source = File.read(File.expand_path("../examples/codecs.rb", __dir__))

    refute_includes source, "instance_variable_get"
    refute_includes source, "__reconstruct__"
    refute_includes source, "_aj_serialized"
    refute_includes source, "EventSerializer"
    refute_includes source, "Internal"
  end

  # --- 7.6 an inbound consumer and an outbound bridge ----------------------------

  test "an inbound consumer publishes internally and acknowledges only after success" do
    message = ExampleTransport::Message.new(payload: external_payload)
    consumer = ExampleTransport::InboundConsumer.new(allowlist: ALLOWLIST)

    assert consumer.consume(message)
    assert_predicate message, :acked?

    perform_enqueued_jobs
    relayed = BoundaryFixtures::OnPlaced.received.sole

    assert_equal "ext-1", relayed.id, "an external event keeps its own identity"
    assert_equal "partner.orders", relayed.source
    assert_equal Time.utc(2026, 8, 1), relayed.occurred_at
    assert_equal "ext-corr", relayed.correlation_id
    assert_equal({ "region" => "eu" }, relayed.extensions)
  end

  test "a contract outside the allowlist is refused and left unacknowledged" do
    envelope = EventRail::Envelope.new(
      contract: EventRail::Contract.new(event_type: "partner.unknown", version: 1),
      metadata: external_metadata,
      data: { "order_id" => "o-1" }
    )
    message = ExampleTransport::Message.new(payload: ExampleCodecs::CloudEventsJson.encode(envelope))

    refute ExampleTransport::InboundConsumer.new(allowlist: ALLOWLIST).consume(message)
    refute_predicate message, :acked?
    assert_empty enqueued_jobs, "failure leaves acknowledgement and routing to the transport"
  end

  test "a malformed payload is refused and left unacknowledged" do
    message = ExampleTransport::Message.new(payload: "{not json")

    refute ExampleTransport::InboundConsumer.new(allowlist: ALLOWLIST).consume(message)
    refute_predicate message, :acked?
  end

  test "a consumer never resolves a Ruby constant from the payload" do
    envelope = EventRail::Envelope.new(
      contract: EventRail::Contract.new(event_type: "BoundaryFixtures::Placed", version: 1),
      metadata: external_metadata,
      data: { "order_id" => "o-1" }
    )
    message = ExampleTransport::Message.new(payload: ExampleCodecs::CloudEventsJson.encode(envelope))

    refute ExampleTransport::InboundConsumer.new(allowlist: ALLOWLIST).consume(message)
  end

  test "the export policy stops a relayed event from bouncing back" do
    transport = ExampleTransport::FakeTransport.new
    bridge = ExampleTransport::OutboundBridge.new(
      policy: ExampleTransport::ExportPolicy.new(
        local_source: "acme.orders", exportable_types: [ "tests.boundary_placed" ]
      ),
      transport: transport
    )

    local = published
    relayed = relay_external

    assert_equal :delivered, bridge.deliver(local)
    assert_equal :skipped, bridge.deliver(relayed),
      "an event this application did not produce must not be exported back to its origin"
    assert_equal 1, transport.published.length
  end

  test "the export policy skips a local event the application has not chosen to export" do
    transport = ExampleTransport::FakeTransport.new
    bridge = ExampleTransport::OutboundBridge.new(
      policy: ExampleTransport::ExportPolicy.new(local_source: "acme.orders", exportable_types: []),
      transport: transport
    )

    assert_equal :skipped, bridge.deliver(published)
    assert_empty transport.published
  end

  test "EventRail itself knows nothing about direction, topics, or transports" do
    refute_respond_to EventRail, :transport
    refute_respond_to EventRail, :topic_for
    refute_respond_to EventRail, :export
    refute_respond_to EventRail, :configure
  end

  private
    def assert_round_trips(codec)
      event = published
      envelope = EventRail::Envelope.of(event)

      decoded = codec.decode(codec.encode(envelope))

      assert_equal envelope, decoded
      assert_equal event, decoded.to_event(BoundaryFixtures::Placed)
      assert_equal BigDecimal("12.5"), decoded.to_event(BoundaryFixtures::Placed).total
      assert_equal Date.new(2026, 9, 1), decoded.to_event(BoundaryFixtures::Placed).placed_on
      assert_equal(
        [ "a", "b" ], decoded.to_event(BoundaryFixtures::Placed).lines.map(&:sku)
      )
    end

    def published
      EventRail.publish(
        BoundaryFixtures::Placed.new(**INPUT, extensions: { "tenant" => "acme" })
      ).event
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

    def external_envelope
      EventRail::Envelope.new(
        contract: EventRail::Contract.new(event_type: "tests.boundary_placed", version: 1),
        metadata: external_metadata,
        data: { "order_id" => "o-ext" }
      )
    end

    def external_payload
      ExampleCodecs::CloudEventsJson.encode(external_envelope)
    end

    def relay_external
      external_envelope.to_event(BoundaryFixtures::Placed)
    end
end
