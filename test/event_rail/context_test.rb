require "test_helper"

class ContextTest < ActiveSupport::TestCase
  setup { EventRail::Current.reset }
  teardown { EventRail::Current.reset }

  test "a boundary generates a message ID, roots correlation on it, and captures origin time" do
    before = Time.now.utc

    EventRail.with_context do
      assert_match(/\A[0-9a-f-]{36}\z/, EventRail::Current.message_id)
      assert_equal EventRail::Current.message_id, EventRail::Current.correlation_id
      assert_nil EventRail::Current.causation_id
      assert_operator EventRail::Current.originated_at, :>=, before.floor(6)
      assert_equal "UTC", EventRail::Current.originated_at.zone
    end
  end

  test "a boundary accepts a trusted message identifier" do
    EventRail.with_context(message_id: "req-1") do
      assert_equal "req-1", EventRail::Current.message_id
      assert_equal "req-1", EventRail::Current.correlation_id
    end
  end

  test "a boundary installs explicit extensions and nothing else" do
    EventRail.with_context(extensions: { "tenant" => "acme" }) do
      assert_equal({ "tenant" => "acme" }, EventRail::Current.extensions)
      assert_predicate EventRail::Current.extensions, :frozen?
    end
  end

  test "a nested boundary inherits lineage and may add extensions" do
    EventRail.with_context(message_id: "req-1", extensions: { "tenant" => "acme" }) do
      origin = EventRail::Current.originated_at

      EventRail.with_context(extensions: { "locale" => "de" }) do
        assert_equal "req-1", EventRail::Current.message_id
        assert_equal "req-1", EventRail::Current.correlation_id
        assert_equal origin, EventRail::Current.originated_at
        assert_equal({ "tenant" => "acme", "locale" => "de" }, EventRail::Current.extensions)
      end

      assert_equal({ "tenant" => "acme" }, EventRail::Current.extensions)
    end
  end

  test "a nested boundary may repeat an identical value" do
    EventRail.with_context(message_id: "req-1", extensions: { "tenant" => "acme" }) do
      EventRail.with_context(message_id: "req-1", extensions: { "tenant" => "acme" }) do
        assert_equal "req-1", EventRail::Current.message_id
      end
    end
  end

  test "a nested boundary cannot replace inherited lineage" do
    EventRail.with_context(message_id: "req-1", extensions: { "tenant" => "acme" }) do
      assert_raises(EventRail::InvalidContext) { EventRail.with_context(message_id: "req-2") { } }
      assert_raises(EventRail::InvalidContext) { EventRail.with_context(correlation_id: "other") { } }
      assert_raises(EventRail::InvalidContext) do
        EventRail.with_context(originated_at: Time.utc(2000, 1, 1)) { }
      end
      assert_raises(EventRail::InvalidContext) do
        EventRail.with_context(extensions: { "tenant" => "other" }) { }
      end
    end
  end

  test "a boundary rejects an unbounded identifier, a zoneless origin time, and invalid extensions" do
    assert_raises(EventRail::InvalidContext) { EventRail.with_context(message_id: "") { } }
    assert_raises(EventRail::InvalidContext) do
      EventRail.with_context(message_id: "m" * (EventRail::Limits::MAX_IDENTIFIER_BYTES + 1)) { }
    end
    assert_raises(EventRail::InvalidContext) { EventRail.with_context(originated_at: "2026-09-01 10:00:00") { } }
    assert_raises(EventRail::InvalidContext) { EventRail.with_context(extensions: { traceparent: "x" }) { } }
    assert_raises(EventRail::InvalidContext) { EventRail.with_context(extensions: { "traceparent" => "x" }) { } }
  end

  test "context is restored after normal and exceptional completion" do
    EventRail.with_context(message_id: "req-1") do
      EventRail.with_context(extensions: { "a" => "1" }) { nil }
      assert_empty EventRail::Current.extensions

      assert_raises(RuntimeError) do
        EventRail.with_context(extensions: { "a" => "1" }) { raise "boom" }
      end
      assert_empty EventRail::Current.extensions
      assert_equal "req-1", EventRail::Current.message_id
    end

    assert_nil EventRail::Current.message_id
    assert_empty EventRail::Current.extensions
  end

  test "context does not leak between threads" do
    EventRail.with_context(message_id: "req-1") do
      seen = Thread.new { EventRail::Current.message_id }.value

      assert_nil seen, "lineage must be isolated per unit of concurrent execution"
    end
  end

  test "the boundary supplies a publishing execution that derives no identity" do
    EventRail.with_context(message_id: "req-1") do
      execution = EventRailInternal::Execution.current

      assert_equal "req-1", execution.scope
      assert_nil execution.job_class
      refute_predicate execution, :derives_identity?
    end

    assert_nil EventRailInternal::Execution.current
  end
end
