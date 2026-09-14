require "test_helper"

module MetadataFixtures
  class AccountOpened < EventRail::Event
    event_type "accounts.account_opened"
    version 1
    default_source "acme.accounts"
    identity_by :account_id

    attribute :account_id, :string
    attribute :owner_name, :string

    validates :account_id, presence: true
  end
end

module StampFixtures
  class << self
    attr_accessor :validation_runs, :items_built

    def reset
      self.validation_runs = 0
      self.items_built = 0
    end
  end
  reset

  class LineItem < EventRail::Data
    attribute :sku, :string
    attribute :quantity, :integer

    validate { StampFixtures.validation_runs += 1 }

    # Counted on initialize rather than on new, so it measures construction through
    # every entry point including trusted reconstruction, which allocates directly.
    def initialize(...)
      StampFixtures.items_built += 1
      super
    end
  end

  class Order < EventRail::Event
    event_type "tests.stamp_order"
    version 1
    default_source "tests"

    attribute :order_id, :string
    attribute :line_items, LineItem, array: true

    validate { StampFixtures.validation_runs += 1 }

    attr_reader :installed_by_initializer

    def initialize(...)
      @installed_by_initializer = "installed"
      super
    end
  end
end

class MetadataAndReconstructionTest < ActiveSupport::TestCase
  test "local construction accepts occurrence time and extensions without forged lineage" do
    event = MetadataFixtures::AccountOpened.new(
      account_id: "account-1",
      occurred_at: "2026-09-01T12:34:56.123456789+02:00",
      extensions: { "actor_type" => "customer" }
    )

    assert_nil event.id
    assert_nil event.source
    assert_nil event.correlation_id
    assert_nil event.causation_id
    assert_equal Time.utc(2026, 9, 1, 10, 34, 56, 123_456), event.occurred_at
    assert_equal({ "actor_type" => "customer" }, event.extensions)
    refute_predicate event, :stamped?

    %i[id source correlation_id causation_id].each do |field|
      assert_raises(EventRail::InvalidEvent) do
        MetadataFixtures::AccountOpened.new(account_id: "1", field => "forged")
      end
    end
  end

  test "stamping returns a distinct complete event and leaves the proposal unchanged" do
    proposal = MetadataFixtures::AccountOpened.new(
      account_id: "account-1",
      owner_name: "Ada",
      occurred_at: Time.utc(2026, 9, 1),
      extensions: { "actor" => "customer" }
    )

    stamped = proposal.send(:__stamp__,
      id: "evt-123",
      correlation_id: "corr-123",
      causation_id: "cause-123"
    )

    refute_same proposal, stamped
    assert_nil proposal.id
    assert_equal "evt-123", stamped.id
    assert_equal "acme.accounts", stamped.source
    assert_equal "corr-123", stamped.correlation_id
    assert_equal "cause-123", stamped.causation_id
    assert_equal proposal.attributes, stamped.attributes
    assert_predicate stamped, :stamped?
    assert_predicate stamped.metadata, :frozen?
    assert_predicate stamped.extensions, :frozen?
  end

  test "trusted reconstruction preserves opaque unknown portable fields" do
    metadata = complete_metadata
    reconstructed = MetadataFixtures::AccountOpened.send(:__reconstruct__,
      data: {
        "account_id" => "account-1",
        "owner_name" => "Ada",
        "future_field" => { "flags" => [ true, "new" ] }
      },
      metadata: metadata
    )

    assert_equal "account-1", reconstructed.account_id
    refute_respond_to reconstructed, :future_field
    refute_includes reconstructed.attributes.keys, "future_field"
    assert_equal({ "flags" => [ true, "new" ] }, reconstructed.data.fetch("future_field"))
    assert_raises(FrozenError) { reconstructed.data.fetch("future_field").fetch("flags") << false }

    restamped = reconstructed.send(:__stamp__,
      id: reconstructed.id,
      source: reconstructed.source,
      occurred_at: reconstructed.occurred_at,
      correlation_id: reconstructed.correlation_id,
      causation_id: reconstructed.causation_id,
      extensions: reconstructed.extensions
    )
    assert_equal reconstructed.data, restamped.data
  end

  test "trusted reconstruction rejects malformed or unsupported unknown data" do
    assert_raises(EventRail::InvalidEvent) do
      MetadataFixtures::AccountOpened.send(:__reconstruct__,
        data: { account_id: "symbol-key" },
        metadata: complete_metadata
      )
    end
    assert_raises(EventRail::CastingError) do
      MetadataFixtures::AccountOpened.send(:__reconstruct__,
        data: { "account_id" => "1", "future" => :symbol_value },
        metadata: complete_metadata
      )
    end
  end

  test "validates timezone and fixed identifier, source, and extension limits" do
    assert_raises(EventRail::InvalidMetadata) do
      EventRail::Metadata.complete(
        id: "id",
        source: "source",
        occurred_at: nil,
        correlation_id: "correlation"
      )
    end
    assert_raises(EventRail::InvalidMetadata) do
      MetadataFixtures::AccountOpened.new(account_id: "1", occurred_at: "2026-09-01 12:00:00")
    end
    assert_raises(EventRail::InvalidMetadata) do
      EventRail::Metadata.complete(
        id: "i" * (EventRail::Limits::MAX_IDENTIFIER_BYTES + 1),
        source: "source",
        occurred_at: Time.now.utc,
        correlation_id: "correlation"
      )
    end
    assert_raises(EventRail::InvalidMetadata) do
      EventRail::Metadata.complete(
        id: "id",
        source: "s" * (EventRail::Limits::MAX_SOURCE_BYTES + 1),
        occurred_at: Time.now.utc,
        correlation_id: "correlation"
      )
    end
    assert_raises(EventRail::InvalidMetadata) do
      MetadataFixtures::AccountOpened.new(account_id: "1", extensions: { "traceparent" => "secret" })
    end
    assert_raises(EventRail::InvalidMetadata) do
      MetadataFixtures::AccountOpened.new(account_id: "1", extensions: { actor: "customer" })
    end
    assert_raises(EventRail::InvalidMetadata) do
      extensions = (EventRail::Limits::MAX_EXTENSION_ENTRIES + 1).times.to_h { |index| [ "k#{index}", "v" ] }
      MetadataFixtures::AccountOpened.new(account_id: "1", extensions: extensions)
    end
    assert_raises(EventRail::InvalidMetadata) do
      key = "k" * (EventRail::Limits::MAX_EXTENSION_KEY_BYTES + 1)
      MetadataFixtures::AccountOpened.new(account_id: "1", extensions: { key => "v" })
    end
    assert_raises(EventRail::InvalidMetadata) do
      value = "v" * (EventRail::Limits::MAX_EXTENSION_VALUE_BYTES + 1)
      MetadataFixtures::AccountOpened.new(account_id: "1", extensions: { "key" => value })
    end
    assert_raises(EventRail::InvalidMetadata) do
      extensions = EventRail::Limits::MAX_EXTENSION_ENTRIES.times.to_h do |index|
        [ "key-#{index}", "v" * EventRail::Limits::MAX_EXTENSION_VALUE_BYTES ]
      end
      MetadataFixtures::AccountOpened.new(account_id: "1", extensions: extensions)
    end
  end

  test "does not accept delivery facts as event payload or metadata" do
    %i[provider_job_id queue_attempt broker_offset traceparent].each do |field|
      assert_raises(EventRail::InvalidEvent) do
        MetadataFixtures::AccountOpened.new(account_id: "1", field => "delivery")
      end
    end
  end

  test "stamping copies canonical state instead of rebuilding it" do
    StampFixtures.reset
    proposal = StampFixtures::Order.new(
      order_id: "o-1",
      line_items: [ { sku: "a", quantity: 1 }, { sku: "b", quantity: 2 } ]
    )

    assert_equal 3, StampFixtures.validation_runs
    assert_equal 2, StampFixtures.items_built

    StampFixtures.reset
    stamped = proposal.send(:__stamp__, id: "evt-1", correlation_id: "corr-1", occurred_at: Time.utc(2026, 9, 1))

    assert_equal 0, StampFixtures.validation_runs, "stamping must not re-run application validations"
    assert_equal 0, StampFixtures.items_built, "stamping must not rebuild nested data"
    assert_equal proposal.attributes, stamped.attributes
    assert_predicate stamped, :frozen?
    assert_predicate stamped, :stamped?
    assert_nil proposal.id
    assert_equal "evt-1", stamped.id
    assert_instance_of StampFixtures::LineItem, stamped.line_items.first
  end

  test "stamping preserves state an application initializer installed" do
    StampFixtures.reset
    proposal = StampFixtures::Order.new(order_id: "o-1")
    stamped = proposal.send(:__stamp__, id: "evt-1", correlation_id: "corr-1", occurred_at: Time.utc(2026, 9, 1))

    assert_equal "installed", stamped.installed_by_initializer
  end

  test "reconstruction from portable input still casts and validates" do
    StampFixtures.reset
    reconstructed = StampFixtures::Order.send(:__reconstruct__,
      data: { "order_id" => "o-9", "line_items" => [ { "sku" => "a", "quantity" => "4" } ] },
      metadata: complete_metadata
    )

    assert_equal 2, StampFixtures.validation_runs, "wire input must be validated"
    assert_equal 1, StampFixtures.items_built, "wire input must be rebuilt as typed data"
    assert_equal 4, reconstructed.line_items.first.quantity

    assert_raises(EventRail::CastingError) do
      StampFixtures::Order.send(:__reconstruct__,
        data: { "order_id" => "o-9", "line_items" => [ { "sku" => "a", "quantity" => "abc" } ] },
        metadata: complete_metadata
      )
    end
  end

  test "the internal construction channel is not reachable through new" do
    error = assert_raises(EventRail::InvalidEvent) do
      MetadataFixtures::AccountOpened.new(
        account_id: "1", __event_rail_internal__: [ Object.new, nil, {} ]
      )
    end

    assert_includes error.message, "__event_rail_internal__"
    refute EventRail::Event.const_defined?(:INTERNAL_TOKEN, false)
  end

  test "names metadata supplied as attribute data instead of reporting it unknown" do
    keyword_error = assert_raises(EventRail::InvalidEvent) do
      MetadataFixtures::AccountOpened.new({ "account_id" => "1", "occurred_at" => Time.now.utc })
    end
    assert_includes keyword_error.message, "occurred_at"
    assert_includes keyword_error.message, "keyword argument"

    derived_error = assert_raises(EventRail::InvalidEvent) do
      MetadataFixtures::AccountOpened.new(account_id: "1", id: "forged", source: "forged")
    end
    assert_includes derived_error.message, "cannot be set locally"
    assert_includes derived_error.message, "validated reconstruction"

    mixed_error = assert_raises(EventRail::InvalidEvent) do
      MetadataFixtures::AccountOpened.new(account_id: "1", id: "forged", provider_job_id: "delivery")
    end
    assert_includes mixed_error.message, "cannot be set locally"
    assert_includes mixed_error.message, "unknown attributes: provider_job_id"
  end

  private
    def complete_metadata
      EventRail::Metadata.complete(
        id: "external-event-id",
        source: "external.accounts",
        occurred_at: Time.utc(2026, 9, 1),
        correlation_id: "external-correlation",
        extensions: { "tenant" => "north" }
      )
    end
end
