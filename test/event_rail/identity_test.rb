require "test_helper"

class IdentityTest < ActiveSupport::TestCase
  Identity = EventRailInternal::Identity

  # These vectors are compatibility state, not test scaffolding. Every one of them
  # changing means every future publication derives a different ID for an unchanged
  # fact, so a change here is a breaking release, and an accidental change fails
  # loudly instead of shipping.
  test "the namespace is permanent" do
    assert_equal "fbedbd9d-81ce-5ddb-b7aa-a0eb701133a3", Identity::NAMESPACE
  end

  test "the encoding is length-delimited and type-tagged" do
    assert_equal "s2:ab", Identity.encode_component("ab")
    assert_equal "i1:1", Identity.encode_component(1)
    assert_equal "b4:true", Identity.encode_component(true)
    assert_equal "b5:false", Identity.encode_component(false)
    assert_equal "d4:12.5", Identity.encode_component(BigDecimal("12.50"))
    assert_equal "D10:2026-09-01", Identity.encode_component(Date.new(2026, 9, 1))
    assert_equal "T27:2026-09-01T10:30:00.000000Z", Identity.encode_component(Time.utc(2026, 9, 1, 10, 30))
    assert_equal "*0:", Identity.encode_component(Identity::SINGLETON)
  end

  test "the encoding distinguishes value types" do
    refute_equal Identity.encode_component("1"), Identity.encode_component(1)
    refute_equal Identity.encode_component(1), Identity.encode_component(1.0)
    refute_equal Identity.encode_component("true"), Identity.encode_component(true)
    refute_equal Identity.encode_component(BigDecimal("1")), Identity.encode_component(1)
  end

  test "the encoding distinguishes tuple boundaries" do
    refute_equal Identity.encode_component([ "ab", "c" ]), Identity.encode_component([ "a", "bc" ])
    refute_equal Identity.encode_component([ "a" ]), Identity.encode_component("a")
    refute_equal Identity.encode_component([ "a", "" ]), Identity.encode_component([ "a" ])
  end

  test "derivation is deterministic across processes" do
    assert_equal "1b66451c-3904-5cae-a184-28f778beaf9b", derive(logical_identity: [ "o-1" ])
    assert_equal "6be71e8b-b850-5f12-8287-30f3fd587cc8", derive(logical_identity: Identity::SINGLETON)
    assert_equal "a452fe23-62ef-59c9-adf3-e121a71f3ea0", derive(logical_identity: "key-1")
  end

  test "every component changes the derived identity" do
    base = derive(logical_identity: [ "o-1" ])

    refute_equal base, derive(source: "other.orders", logical_identity: [ "o-1" ])
    refute_equal base, derive(job_class: "Orders::OtherJob", logical_identity: [ "o-1" ])
    refute_equal base, derive(scope: "job-2", logical_identity: [ "o-1" ])
    refute_equal base, derive(event_type: "orders.order_shipped", logical_identity: [ "o-1" ])
    refute_equal base, derive(version: 2, logical_identity: [ "o-1" ])
    refute_equal base, derive(logical_identity: [ "o-2" ])
  end

  test "a structured or null component cannot identify a publication" do
    [ nil, [ nil ], [ [ "a" ] ], [ { "a" => 1 } ], Float::INFINITY, [ Float::NAN ] ].each do |value|
      assert_raises(EventRail::PublicationError, "#{value.inspect} must be rejected") do
        derive(logical_identity: value)
      end
    end
  end

  test "a DateTime component is refused rather than silently narrowed" do
    assert_raises(EventRail::PublicationError) do
      derive(logical_identity: [ DateTime.new(2026, 9, 1) ])
    end
  end

  private
    def derive(
      source: "acme.orders",
      job_class: "Orders::PlaceOrderJob",
      scope: "job-1",
      event_type: "orders.order_placed",
      version: 1,
      logical_identity:
    )
      Identity.derive(
        source: source,
        job_class: job_class,
        scope: scope,
        event_type: event_type,
        version: version,
        logical_identity: logical_identity
      )
    end
end
