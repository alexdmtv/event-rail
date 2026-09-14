require "test_helper"

module EventAndDataFixtures
  class LineItem < EventRail::Data
    attribute :product_id, :string
    attribute :quantity, :integer

    validates :product_id, presence: true
    validates :quantity, numericality: { greater_than: 0 }
  end

  class OrderPlaced < EventRail::Event
    event_type "orders.order_placed"
    version 1
    default_source "acme.orders"
    identity_by :order_id

    attribute :order_id, :string
    attribute :line_items, LineItem, array: true
    attribute :properties
    attribute :tags, :string, array: true
    attribute :total, :decimal
    attribute :delivery_on, :date

    validates :order_id, presence: true
  end

  class GlobalRecord
    def to_global_id
      "gid://example/Record/1"
    end
  end

  class Measurement < EventRail::Event
    event_type "tests.measurement"
    version 1
    default_source "tests"

    attribute :count, :integer
    attribute :ratio, :float
    attribute :amount, :decimal
    attribute :flag, :boolean
    attribute :recorded_at, :datetime
    attribute :recorded_on, :date
  end

  class Counted < EventRail::Event
    event_type "tests.counted"
    version 1
    default_source "tests"

    attribute :order_id, :string

    class << self
      attr_accessor :validation_runs
    end
    self.validation_runs = 0

    validate { self.class.validation_runs += 1 }
  end
end

class EventAndDataTest < ActiveSupport::TestCase
  test "casts scalar and typed nested values into an immutable attributes view" do
    event = EventAndDataFixtures::OrderPlaced.new(
      order_id: "123",
      line_items: [ { product_id: "456", quantity: "2" } ],
      tags: [ "priority" ],
      total: "12.50",
      delivery_on: "2026-09-01"
    )

    item = event.line_items.first

    assert_instance_of EventAndDataFixtures::LineItem, item
    assert_equal "123", event.order_id
    assert_equal "456", item.product_id
    assert_equal 2, item.quantity
    assert_equal [ "priority" ], event.tags
    assert_equal BigDecimal("12.50"), event.total
    assert_equal Date.new(2026, 9, 1), event.delivery_on

    # Active Model's own meaning: cast values of the declared types, so a nested
    # record stays a record and a decimal stays a decimal.
    assert_equal(
      {
        "order_id" => "123",
        "line_items" => [ item ],
        "properties" => nil,
        "tags" => [ "priority" ],
        "total" => BigDecimal("12.50"),
        "delivery_on" => Date.new(2026, 9, 1)
      },
      event.attributes
    )

    # The written projection of the same payload carries JSON primitives only.
    assert_equal(
      {
        "order_id" => "123",
        "line_items" => [ { "product_id" => "456", "quantity" => 2 } ],
        "properties" => nil,
        "tags" => [ "priority" ],
        "total" => "12.5",
        "delivery_on" => "2026-09-01"
      },
      event.data
    )

    assert_predicate event, :frozen?
    assert_predicate item, :frozen?
    assert_predicate event.data, :frozen?

    # The attributes view is a dump, so mutating it cannot reach the event.
    view = event.attributes
    view["order_id"] = "tampered"
    assert_equal "123", event.order_id
  end

  test "deep copies and freezes raw JSON-like data" do
    source = { "shipping" => { "methods" => [ "ground", true, nil, 2, 1.5 ] } }
    event = EventAndDataFixtures::OrderPlaced.new(order_id: "1", properties: source)

    source.fetch("shipping").fetch("methods") << "overnight"

    assert_equal [ "ground", true, nil, 2, 1.5 ], event.properties.dig("shipping", "methods")
    assert_raises(FrozenError) { event.properties["shipping"] = {} }
    assert_raises(FrozenError) { event.properties.dig("shipping", "methods") << "overnight" }
    assert_raises(FrozenError) { event.order_id << "2" }
    assert_raises(FrozenError) { event.order_id = "2" }
  end

  test "rejects unsupported raw values, symbols, non-finite floats, and records" do
    assert_raises(EventRail::CastingError) do
      EventAndDataFixtures::OrderPlaced.new(order_id: "1", properties: { "status" => :placed })
    end
    assert_raises(EventRail::CastingError) do
      EventAndDataFixtures::OrderPlaced.new(order_id: "1", properties: Float::INFINITY)
    end
    assert_raises(EventRail::CastingError) do
      EventAndDataFixtures::OrderPlaced.new(order_id: "1", total: BigDecimal("Infinity"))
    end
    assert_raises(EventRail::CastingError) do
      EventAndDataFixtures::OrderPlaced.new(order_id: "1", properties: Object.new)
    end
    assert_raises(EventRail::CastingError) do
      EventAndDataFixtures::OrderPlaced.new(order_id: EventAndDataFixtures::GlobalRecord.new)
    end
    assert_raises(EventRail::CastingError) do
      EventAndDataFixtures::OrderPlaced.new(order_id: GlobalID.allocate)
    end
  end

  test "rejects invalid nested shapes and validations after casting" do
    error = assert_raises(EventRail::InvalidData) do
      EventAndDataFixtures::OrderPlaced.new(
        order_id: "1",
        line_items: [ { product_id: "sku", quantity: "0" } ]
      )
    end

    assert_includes error.validation_errors.fetch(:quantity), "Quantity must be greater than 0"
    assert_raises(EventRail::CastingError) do
      EventAndDataFixtures::OrderPlaced.new(order_id: "1", line_items: { product_id: "sku" })
    end
  end

  test "rejects scalar casts that would discard information" do
    [
      [ :count, "12abc" ], [ :count, "abc" ], [ :count, "" ], [ :count, 1.9 ], [ :count, true ],
      [ :ratio, "1.5x" ],
      [ :amount, "abc" ],
      [ :flag, "maybe" ], [ :flag, "yes" ], [ :flag, 7 ],
      [ :recorded_at, "garbage" ],
      [ :recorded_on, "garbage" ]
    ].each do |attribute_name, value|
      assert_raises(
        EventRail::CastingError,
        "expected #{attribute_name}=#{value.inspect} to be rejected"
      ) { EventAndDataFixtures::Measurement.new(attribute_name => value) }
    end
  end

  test "accepts lossless scalar input in local and portable forms" do
    event = EventAndDataFixtures::Measurement.new(
      count: "12",
      ratio: "1.5",
      amount: "12.50",
      flag: "false",
      recorded_at: "2026-09-01T10:00:00Z",
      recorded_on: "2026-09-01"
    )

    assert_equal 12, event.count
    assert_in_delta 1.5, event.ratio
    assert_equal BigDecimal("12.50"), event.amount
    assert_equal false, event.flag
    assert_equal Time.utc(2026, 9, 1, 10), event.recorded_at
    assert_equal Date.new(2026, 9, 1), event.recorded_on
    assert_equal 2, EventAndDataFixtures::Measurement.new(count: 2.0).count
  end

  test "copies of an event remain immutable" do
    event = EventAndDataFixtures::OrderPlaced.new(order_id: "1", properties: { "a" => "b" })

    [ event.dup, event.clone, event.clone(freeze: false) ].each do |copy|
      assert_predicate copy, :frozen?
      assert_equal event.attributes, copy.attributes
      assert_equal event.order_id, copy.attributes.fetch("order_id")
      assert_raises(FrozenError) { copy.instance_variable_set(:@order_id, "mutated") }
    end
  end

  test "a validity query does not re-run application validations" do
    EventAndDataFixtures::Counted.validation_runs = 0
    event = EventAndDataFixtures::Counted.new(order_id: "1")

    assert_equal 1, EventAndDataFixtures::Counted.validation_runs
    assert_predicate event, :valid?
    assert_empty event.errors
    assert_equal 1, EventAndDataFixtures::Counted.validation_runs
  end

  test "diagnostic output identifies the contract without exposing payload" do
    event = EventAndDataFixtures::OrderPlaced.new(
      order_id: "secret-order",
      properties: { "pan" => "secret-pan" },
      line_items: [ { product_id: "secret-sku", quantity: 1 } ],
      extensions: { "actor" => "secret-actor" }
    )
    stamped = event.send(:__stamp__, id: "evt-1", correlation_id: "corr-1", occurred_at: Time.now.utc)

    [ event.inspect, stamped.inspect, event.line_items.first.inspect ].each do |representation|
      refute_includes representation, "secret-order"
      refute_includes representation, "secret-pan"
      refute_includes representation, "secret-sku"
      refute_includes representation, "secret-actor"
    end

    assert_includes stamped.inspect, "orders.order_placed"
    assert_includes stamped.inspect, "evt-1"
    assert_includes stamped.inspect, "acme.orders"
  end
end
