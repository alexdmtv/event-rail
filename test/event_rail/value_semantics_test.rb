require "test_helper"

# These fixtures are defined after the host application has been prepared, which is the case
# the registry refuses by default. The declaration window is the public door for it.
EventRail::TestHelper.declare do
  module ValueFixtures
    class Address < EventRail::Data
      attribute :city, :string
    end

    class Shipped < EventRail::Event
      event_type "tests.value_shipped"
      version 1
      default_source "tests"

      attribute :order_id, :string
      attribute :total, :decimal
      attribute :address, Address
    end

    class Keyed < EventRail::Event
      event_type "tests.value_keyed"
      version 1
      default_source "tests"

      attribute :order_id, :string
      attribute :note, :string
      identity_by :order_id
    end

    def self.complete_metadata(id: "evt-1", occurred_at: Time.utc(2026, 9, 1))
      EventRail::Metadata.complete(
        id: id,
        source: "tests",
        occurred_at: occurred_at,
        correlation_id: "corr-1"
      )
    end
  end
end

class ValueSemanticsTest < ActiveSupport::TestCase
  INPUT = { order_id: "o-1", total: "12.50", address: { city: "Berlin" } }.freeze

  # --- 2.15 nested data reconstructs unknown fields ----------------------------

  test "an unknown field inside nested data reconstructs and is preserved for export" do
    event = ValueFixtures::Shipped.send(
      :__reconstruct__,
      data: {
        "order_id" => "o-1",
        "total" => "12.5",
        "address" => { "city" => "Berlin", "what3words" => "index.home.raft" }
      },
      metadata: ValueFixtures.complete_metadata
    )

    address = event.address

    assert_equal "Berlin", address.city
    refute_respond_to address, :what3words
    assert_equal "index.home.raft", address.data.fetch("what3words")
    assert_equal "index.home.raft", event.data.fetch("address").fetch("what3words")
  end

  test "an unknown field inside nested data still fails local construction" do
    error = assert_raises(EventRail::InvalidData) do
      ValueFixtures::Shipped.new(order_id: "o-1", address: { city: "Berlin", what3words: "a.b.c" })
    end

    assert_match(/what3words/, error.message)
  end

  test "an unknown field inside a nested array item reconstructs" do
    event_class = Class.new(EventRail::Event) do
      event_type "tests.value_nested_array"
      version 1
      default_source "tests"

      attribute :stops, ValueFixtures::Address, array: true
    end

    event = event_class.send(
      :__reconstruct__,
      data: { "stops" => [ { "city" => "Berlin", "zone" => "eu" } ] },
      metadata: ValueFixtures.complete_metadata
    )

    assert_equal "eu", event.stops.first.data.fetch("zone")
  end

  # --- 2.18 value equality -----------------------------------------------------

  test "two structurally identical events compare equal and hash alike" do
    metadata = ValueFixtures.complete_metadata
    one = ValueFixtures::Shipped.send(:__reconstruct__, data: identical_data, metadata: metadata)
    two = ValueFixtures::Shipped.send(:__reconstruct__, data: identical_data, metadata: ValueFixtures.complete_metadata)

    assert_equal one, two
    assert one.eql?(two)
    assert_equal one.hash, two.hash
    assert_equal 1, [ one, two ].uniq.length
  end

  test "events differing in payload, metadata, or class are not equal" do
    metadata = ValueFixtures.complete_metadata
    base = ValueFixtures::Shipped.send(:__reconstruct__, data: identical_data, metadata: metadata)

    other_payload = ValueFixtures::Shipped.send(
      :__reconstruct__, data: identical_data.merge("order_id" => "o-2"), metadata: metadata
    )
    other_metadata = ValueFixtures::Shipped.send(
      :__reconstruct__, data: identical_data, metadata: ValueFixtures.complete_metadata(id: "evt-2")
    )

    refute_equal base, other_payload
    refute_equal base, other_metadata
    refute_equal base, Object.new
  end

  test "a proposal and the stamped event copied from it are different values" do
    proposal = ValueFixtures::Shipped.new(**INPUT)
    stamped = proposal.send(:__stamp__, id: "evt-1", correlation_id: "corr-1", occurred_at: Time.utc(2026, 9, 1))

    refute_equal proposal, stamped
    assert_equal proposal.data, stamped.data
  end

  test "nested data compares by value" do
    assert_equal ValueFixtures::Address.new(city: "Berlin"), ValueFixtures::Address.new(city: "Berlin")
    refute_equal ValueFixtures::Address.new(city: "Berlin"), ValueFixtures::Address.new(city: "Bonn")
    assert_equal(
      ValueFixtures::Address.new(city: "Berlin").hash,
      ValueFixtures::Address.new(city: "Berlin").hash
    )
  end

  test "an unknown preserved field participates in equality" do
    metadata = ValueFixtures.complete_metadata
    plain = ValueFixtures::Shipped.send(:__reconstruct__, data: identical_data, metadata: metadata)
    extended = ValueFixtures::Shipped.send(
      :__reconstruct__, data: identical_data.merge("gift" => true), metadata: metadata
    )

    refute_equal plain, extended
  end

  # --- 2.19 reserved names and private trusted entry points --------------------

  test "a domain name that is only a private Ruby method is available" do
    event_class = Class.new(EventRail::Event) do
      event_type "tests.value_private_names"
      version 1
      default_source "tests"

      attribute :format, :string
      attribute :select, :string
      attribute :open, :string
      attribute :p, :string
      attribute :raise, :string
    end

    event = event_class.new(format: "pdf", select: "all", open: "yes", p: "x", raise: "no")

    assert_equal "pdf", event.format
    assert_equal "all", event.select
    assert_equal "yes", event.open
  end

  test "a name that is a public or protected method is still rejected" do
    %w[freeze frozen? class hash inspect dup attributes data valid? errors metadata].each do |name|
      assert_raises(EventRail::DeclarationError, "#{name} must stay reserved") do
        Class.new(EventRail::Event) do
          event_type "tests.value_reserved_#{name.delete("?")}"
          version 1
          attribute name, :string
        end
      end
    end
  end

  test "a name that is one of the record's own private helpers is rejected" do
    %w[build_data validate_record! normalize_input record_error_class].each do |name|
      assert_raises(EventRail::DeclarationError, "#{name} must stay reserved") do
        Class.new(EventRail::Event) do
          event_type "tests.value_helper_#{name.delete("!")}"
          version 1
          attribute name, :string
        end
      end
    end
  end

  test "application code cannot install metadata through a public entry point" do
    event = ValueFixtures::Shipped.new(**INPUT)

    refute_respond_to event, :__stamp__
    refute_respond_to ValueFixtures::Shipped, :__reconstruct__

    assert_raises(NoMethodError) do
      event.__stamp__(id: "forged", correlation_id: "forged", occurred_at: Time.now.utc)
    end
    assert_raises(NoMethodError) do
      ValueFixtures::Shipped.__reconstruct__(data: {}, metadata: ValueFixtures.complete_metadata)
    end
  end

  # --- a declared identity attribute cannot be nil locally ---------------------

  test "local construction rejects a nil declared identity attribute" do
    error = assert_raises(EventRail::InvalidEvent) do
      ValueFixtures::Keyed.new(note: "no order id")
    end

    assert_match(/order_id/, error.message)
    assert_match(/logical identity/, error.message)
  end

  test "trusted reconstruction accepts a nil declared identity attribute" do
    event = ValueFixtures::Keyed.send(
      :__reconstruct__,
      data: { "note" => "relayed" },
      metadata: ValueFixtures.complete_metadata
    )

    assert_nil event.order_id
    assert_equal "relayed", event.note
  end

  private
    def identical_data
      { "order_id" => "o-1", "total" => "12.5", "address" => { "city" => "Berlin" } }
    end
end
