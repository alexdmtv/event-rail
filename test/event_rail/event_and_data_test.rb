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
end

class EventAndDataTest < ActiveSupport::TestCase
  test "casts scalar and typed nested values into immutable canonical attributes" do
    event = EventAndDataFixtures::OrderPlaced.new(
      order_id: 123,
      line_items: [ { product_id: 456, quantity: "2" } ],
      tags: [ :priority ],
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
    assert_equal(
      {
        "order_id" => "123",
        "line_items" => [ { "product_id" => "456", "quantity" => 2 } ],
        "properties" => nil,
        "tags" => [ "priority" ],
        "total" => BigDecimal("12.50"),
        "delivery_on" => Date.new(2026, 9, 1)
      },
      event.attributes
    )
    assert_predicate event, :frozen?
    assert_predicate item, :frozen?
    assert_predicate event.attributes, :frozen?
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
end
