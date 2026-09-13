require "test_helper"

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
    attribute :tags, :string, array: true
    attribute :properties
    attribute :line_items, LineItem, array: true
  end

  # A custom Active Model type satisfying the portable contract: its cast value is
  # already a portable scalar.
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

  # A custom type that does not satisfy the contract: its cast value is not portable.
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
end

class PortableTypesTest < ActiveSupport::TestCase
  ORDER_INPUT = {
    order_id: "o-1",
    total: "12.50",
    placed_on: "2026-09-01",
    tags: [ "priority", "gift" ],
    properties: { "shipping" => { "methods" => [ "ground", true, nil, 2, 1.5 ] } },
    line_items: [ { sku: "a", quantity: 1 }, { sku: "b", quantity: 2 } ]
  }.freeze

  test "every attribute type round-trips through its portable contract" do
    event = PortableTypeFixtures::Order.new(**ORDER_INPUT)
    types = PortableTypeFixtures::Order.attribute_types

    PortableTypeFixtures::Order.attribute_names.each do |name|
      type = types.fetch(name)
      cast = event.public_send(name)
      portable = type.to_portable(cast)

      assert_equal portable, type.to_portable(type.from_portable(portable)),
        "#{name} did not round-trip through its portable contract"
    end
  end

  test "scalar and raw types export as themselves while nested data flattens" do
    types = PortableTypeFixtures::Order.attribute_types

    assert_predicate types.fetch("order_id"), :portable_identity?
    assert_predicate types.fetch("total"), :portable_identity?
    assert_predicate types.fetch("properties"), :portable_identity?
    assert_predicate types.fetch("tags"), :portable_identity?
    refute_predicate types.fetch("line_items"), :portable_identity?
  end

  test "nested Ruby class names never appear in portable output" do
    event = PortableTypeFixtures::Order.new(**ORDER_INPUT)

    assert_equal(
      [ { "sku" => "a", "quantity" => 1 }, { "sku" => "b", "quantity" => 2 } ],
      event.attributes.fetch("line_items")
    )
    refute_includes event.attributes.inspect, "LineItem"
  end

  test "canonical attributes and their keys are frozen" do
    event = PortableTypeFixtures::Order.new(**ORDER_INPUT)

    assert_predicate event.attributes, :frozen?
    assert event.attributes.keys.all?(&:frozen?)
    assert_predicate event.attributes.fetch("properties"), :frozen?
    assert_predicate event.attributes.fetch("tags"), :frozen?
    assert_raises(FrozenError) { event.attributes.fetch("line_items") << {} }
  end

  test "typed scalars keep their non-JSON semantics in the portable tree" do
    event = PortableTypeFixtures::Order.new(**ORDER_INPUT)

    assert_equal BigDecimal("12.50"), event.attributes.fetch("total")
    assert_equal Date.new(2026, 9, 1), event.attributes.fetch("placed_on")
  end

  test "accepts a custom Active Model type that satisfies the portable contract" do
    event = PortableTypeFixtures::WithCustomType.new(code: "abc")

    assert_equal "ABC", event.code
    assert_equal({ "code" => "ABC" }, event.attributes)
  end

  test "rejects a custom Active Model type whose cast value is not portable" do
    assert_raises(EventRail::CastingError) do
      PortableTypeFixtures::WithOpaqueType.new(code: "abc")
    end
  end
end
