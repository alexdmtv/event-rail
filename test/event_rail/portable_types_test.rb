require "test_helper"
require "json"

module PortableTypeFixtures
  class LineItem < EventRail::Data
    attribute :sku, :string
    attribute :quantity, :integer
  end

  class Order < EventRail::Event
    event_type "tests.portable_order"
    version 1
    default_source "tests"

    attribute :order_id, :string
    attribute :total, :decimal
    attribute :placed_on, :date
    attribute :placed_at, :datetime
    attribute :tags, :string, array: true
    attribute :properties
    attribute :line_items, LineItem, array: true
  end

  # A custom Active Model type whose cast value is already a portable scalar of a
  # type EventRail knows how to write.
  class Upcase < ActiveModel::Type::Value
    def cast(value)
      value.nil? ? nil : value.to_s.upcase
    end

    def type
      :string
    end
  end

  class WithCustomType < EventRail::Event
    event_type "tests.portable_custom"
    version 1
    default_source "tests"

    attribute :code, Upcase.new
  end

  # A custom type that claims a familiar type while casting to something no written
  # form can carry.
  class Opaque < ActiveModel::Type::Value
    def cast(_value)
      Object.new
    end

    def type
      :string
    end
  end

  class WithOpaqueType < EventRail::Event
    event_type "tests.portable_opaque"
    version 1
    default_source "tests"

    attribute :code, Opaque.new
  end

  Money = Struct.new(:cents, :currency) do
    def to_s
      "#{cents} #{currency}"
    end
  end

  # A type EventRail has no written form for, which supplies its own and proves it.
  class MoneyType < ActiveModel::Type::Value
    include EventRail::PortableType

    def cast(value)
      return if value.nil?
      return value if value.is_a?(Money)

      cents, currency = value.split(" ")
      Money.new(Integer(cents), currency)
    end

    def serialize(value)
      value&.to_s
    end

    def deserialize(value)
      cast(value)
    end

    def type
      :money
    end

    def portable_examples
      [ Money.new(0, "USD"), Money.new(1_250, "EUR") ]
    end
  end

  # The same domain type without any written form of its own.
  class BareMoneyType < ActiveModel::Type::Value
    def cast(value)
      return if value.nil?
      return value if value.is_a?(Money)

      cents, currency = value.split(" ")
      Money.new(Integer(cents), currency)
    end

    def type
      :money
    end
  end

  # A type whose written form is a Ruby object, which is exactly the shape that
  # reaches a queue adapter raw.
  class UnwritableType < MoneyType
    def serialize(value)
      value
    end
  end

  # A type whose written form loses information, so it cannot reconstruct its own
  # cast value.
  class LossyType < MoneyType
    def serialize(value)
      value&.cents
    end

    def deserialize(value)
      value.nil? ? nil : Money.new(value, "???")
    end
  end
end

class PortableTypesTest < ActiveSupport::TestCase
  ORDER_INPUT = {
    order_id: "o-1",
    total: "12.50",
    placed_on: "2026-09-01",
    placed_at: "2026-09-01T10:30:00.123456+02:00",
    tags: [ "priority", "gift" ],
    properties: { "shipping" => { "methods" => [ "ground", true, nil, 2, 1.5 ] } },
    line_items: [ { sku: "a", quantity: 1 }, { sku: "b", quantity: 2 } ]
  }.freeze

  def order
    PortableTypeFixtures::Order.new(**ORDER_INPUT)
  end

  # --- 2.13 the attributes view and the portable projection are different things ---

  test "attributes keeps Active Model's meaning and exposes cast values" do
    event = order

    assert_equal BigDecimal("12.50"), event.attributes.fetch("total")
    assert_equal Date.new(2026, 9, 1), event.attributes.fetch("placed_on")
    assert_instance_of Time, event.attributes.fetch("placed_at")
    assert_instance_of PortableTypeFixtures::LineItem, event.attributes.fetch("line_items").first
  end

  test "the portable projection contains no nested data object and no typed scalar" do
    event = order

    assert_equal "12.5", event.data.fetch("total")
    assert_equal "2026-09-01", event.data.fetch("placed_on")
    assert_equal "2026-09-01T08:30:00.123456Z", event.data.fetch("placed_at")
    assert_equal(
      [ { "sku" => "a", "quantity" => 1 }, { "sku" => "b", "quantity" => 2 } ],
      event.data.fetch("line_items")
    )
    refute_includes event.data.inspect, "LineItem"
  end

  test "attributes and the portable projection both agree with the declared readers" do
    event = order

    PortableTypeFixtures::Order.attribute_names.each do |name|
      assert_equal event.public_send(name), event.attributes.fetch(name),
        "#{name} disagrees with the attributes view"
    end

    types = PortableTypeFixtures::Order.attribute_types
    PortableTypeFixtures::Order.attribute_names.each do |name|
      written = types.fetch(name).serialize(event.public_send(name))
      assert_equal written, event.data.fetch(name), "#{name} disagrees with the portable projection"
    end
  end

  test "the portable projection is built once per instance" do
    event = order

    assert_same event.data, event.data
  end

  test "the portable projection is deeply frozen" do
    event = order

    assert_predicate event.data, :frozen?
    assert event.data.keys.all?(&:frozen?)
    assert_predicate event.data.fetch("properties"), :frozen?
    assert_predicate event.data.fetch("total"), :frozen?
    assert_raises(FrozenError) { event.data.fetch("line_items") << {} }
  end

  # --- 2.14 the written form is a JSON primitive that reconstructs the cast value ---

  test "every attribute type round-trips through serialize and deserialize" do
    event = order
    types = PortableTypeFixtures::Order.attribute_types

    PortableTypeFixtures::Order.attribute_names.each do |name|
      type = types.fetch(name)
      cast = event.public_send(name)
      written = type.serialize(cast)

      assert_equal written, JSON.parse(JSON.generate([ written ])).first,
        "#{name} wrote a value a JSON cycle does not preserve"
      assert_equal cast, type.deserialize(written),
        "#{name} did not reconstruct its cast value"
    end
  end

  test "the whole portable projection survives a JSON encoding cycle unchanged" do
    event = order
    decoded = JSON.parse(JSON.generate(event.data))

    assert_equal event.data, decoded

    types = PortableTypeFixtures::Order.attribute_types
    PortableTypeFixtures::Order.attribute_names.each do |name|
      assert_equal event.public_send(name), types.fetch(name).deserialize(decoded.fetch(name)),
        "#{name} did not survive a JSON cycle"
    end
  end

  test "accepts a custom type whose cast value is one EventRail can write" do
    event = PortableTypeFixtures::WithCustomType.new(code: "abc")

    assert_equal "ABC", event.code
    assert_equal({ "code" => "ABC" }, event.data)
  end

  test "accepts a custom type that supplies and proves its own written form" do
    event_class = Class.new(EventRail::Event) do
      event_type "tests.portable_money"
      version 1
      default_source "tests"

      attribute :price, PortableTypeFixtures::MoneyType.new
    end

    event = event_class.new(price: "500 USD")

    assert_equal PortableTypeFixtures::Money.new(500, "USD"), event.price
    assert_equal "500 USD", event.data.fetch("price")
  end

  test "rejects a type EventRail cannot write and which supplies no written form" do
    error = assert_raises(EventRail::DeclarationError) do
      Class.new(EventRail::Event) do
        event_type "tests.portable_bare_money"
        version 1
        attribute :price, PortableTypeFixtures::BareMoneyType.new
      end
    end

    assert_match(/EventRail::PortableType/, error.message)
  end

  test "rejects a custom type whose written form is not a JSON primitive at declaration" do
    error = assert_raises(EventRail::DeclarationError) do
      Class.new(EventRail::Event) do
        event_type "tests.portable_unwritable"
        version 1
        attribute :price, PortableTypeFixtures::UnwritableType.new
      end
    end

    assert_match(/not a JSON primitive/, error.message)
  end

  test "rejects a custom type whose written form cannot reconstruct its cast value" do
    error = assert_raises(EventRail::DeclarationError) do
      Class.new(EventRail::Event) do
        event_type "tests.portable_lossy"
        version 1
        attribute :price, PortableTypeFixtures::LossyType.new
      end
    end

    assert_match(/does not round-trip/, error.message)
  end

  test "rejects a custom type whose cast value no written form can carry" do
    assert_raises(EventRail::CastingError) do
      PortableTypeFixtures::WithOpaqueType.new(code: "abc")
    end
  end

  test "rejects the time-of-day type in favor of the type that keeps the instant" do
    error = assert_raises(EventRail::DeclarationError) do
      Class.new(EventRail::Event) do
        event_type "tests.portable_time_of_day"
        version 1
        attribute :happened_at, :time
      end
    end

    assert_match(/:datetime/, error.message)
  end

  # --- 2.16 losslessness beyond numerics ---------------------------------------

  test "rejects a non-string supplied to a string attribute" do
    [ true, 123, :symbolic ].each do |value|
      error = assert_raises(EventRail::CastingError) do
        PortableTypeFixtures::Order.new(**ORDER_INPUT.merge(order_id: value))
      end

      assert_match(/as string/, error.message)
    end
  end

  test "rejects a declared timestamp with no explicit offset" do
    error = assert_raises(EventRail::CastingError) do
      PortableTypeFixtures::Order.new(**ORDER_INPUT.merge(placed_at: "2026-09-01T10:30:00"))
    end

    assert_match(/explicit UTC offset/, error.message)
  end

  test "rejects a declared timestamp whose offset is outside the valid range" do
    error = assert_raises(EventRail::CastingError) do
      PortableTypeFixtures::Order.new(**ORDER_INPUT.merge(placed_at: "2026-09-01T10:30:00+25:00"))
    end

    assert_match(/outside the valid range/, error.message)
  end

  test "normalizes a declared timestamp to UTC at microsecond precision" do
    event = PortableTypeFixtures::Order.new(
      **ORDER_INPUT.merge(placed_at: "2026-09-01T10:30:00.123456789+02:00")
    )

    assert_equal "UTC", event.placed_at.zone
    assert_equal 123_456, event.placed_at.usec
    assert_equal "2026-09-01T08:30:00.123456Z", event.data.fetch("placed_at")
  end

  test "rejects a date attribute supplied a value carrying a time of day" do
    [ "2026-09-01T10:30:00Z", Time.utc(2026, 9, 1, 10, 30) ].each do |value|
      error = assert_raises(EventRail::CastingError) do
        PortableTypeFixtures::Order.new(**ORDER_INPUT.merge(placed_on: value))
      end

      assert_match(/discarding its time of day/, error.message)
    end
  end

  # --- 2.17 raw structures are bounded -----------------------------------------

  test "rejects a raw key using the prefix Active Job reserves" do
    error = assert_raises(EventRail::CastingError) do
      PortableTypeFixtures::Order.new(**ORDER_INPUT.merge(properties: { "_aj_symbol_keys" => [] }))
    end

    assert_match(/Active Job reserves/, error.message)
  end

  test "rejects a raw structure deeper than the documented limit" do
    deep = (EventRail::Limits::MAX_RAW_DEPTH + 2).times.reduce("leaf") { |inner, _| { "nested" => inner } }

    error = assert_raises(EventRail::CastingError) do
      PortableTypeFixtures::Order.new(**ORDER_INPUT.merge(properties: deep))
    end

    assert_match(/maximum nesting depth/, error.message)
  end

  test "accepts a raw structure at the documented depth limit" do
    deep = (EventRail::Limits::MAX_RAW_DEPTH - 1).times.reduce("leaf") { |inner, _| { "nested" => inner } }

    assert PortableTypeFixtures::Order.new(**ORDER_INPUT.merge(properties: deep))
  end
end
