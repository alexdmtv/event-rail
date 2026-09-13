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

    stamped = proposal.__stamp__(
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
    reconstructed = MetadataFixtures::AccountOpened.__reconstruct__(
      data: {
        "account_id" => "account-1",
        "owner_name" => "Ada",
        "future_field" => { "flags" => [ true, "new" ] }
      },
      metadata: metadata
    )

    assert_equal "account-1", reconstructed.account_id
    refute_respond_to reconstructed, :future_field
    assert_equal({ "flags" => [ true, "new" ] }, reconstructed.attributes.fetch("future_field"))
    assert_raises(FrozenError) { reconstructed.attributes.fetch("future_field").fetch("flags") << false }

    restamped = reconstructed.__stamp__(
      id: reconstructed.id,
      source: reconstructed.source,
      occurred_at: reconstructed.occurred_at,
      correlation_id: reconstructed.correlation_id,
      causation_id: reconstructed.causation_id,
      extensions: reconstructed.extensions
    )
    assert_equal reconstructed.attributes, restamped.attributes
  end

  test "trusted reconstruction rejects malformed or unsupported unknown data" do
    assert_raises(EventRail::InvalidEvent) do
      MetadataFixtures::AccountOpened.__reconstruct__(
        data: { account_id: "symbol-key" },
        metadata: complete_metadata
      )
    end
    assert_raises(EventRail::CastingError) do
      MetadataFixtures::AccountOpened.__reconstruct__(
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
