require "test_helper"
require_relative "identity_vectors"

class IdentityTest < ActiveSupport::TestCase
  Identity = EventRailInternal::Identity

  test "the namespace is permanent" do
    assert_equal "21fedac0-42c6-443f-b01c-6980aab52f32", Identity::NAMESPACE
  end

  IdentityVectors::ALL.each do |vector|
    test "the published vector for #{vector.name} (#{vector.rule}) is reproduced" do
      assert_equal vector.encoded, encoded(vector), "the name string that is hashed"
      assert_equal vector.id, derived(vector)
    end
  end

  test "the encoding is length-delimited and type-tagged" do
    assert_equal "s2:ab", Identity.encode_component("ab")
    assert_equal "i1:1", Identity.encode_component(1)
    assert_equal "b4:true", Identity.encode_component(true)
    assert_equal "d4:12.5", Identity.encode_component(BigDecimal("12.50"))
    assert_equal "D10:2026-09-01", Identity.encode_component(Date.new(2026, 9, 1))
    assert_equal "T27:2026-09-01T10:30:00.000000Z", Identity.encode_component(Time.utc(2026, 9, 1, 10, 30))
    assert_equal "*0:", Identity.encode_component(Identity::SINGLETON)
  end

  test "the encoding distinguishes value types and tuple boundaries" do
    refute_equal Identity.encode_component("1"), Identity.encode_component(1)
    refute_equal Identity.encode_component(1), Identity.encode_component(1.0)
    refute_equal Identity.encode_component(BigDecimal("1")), Identity.encode_component(1)
    refute_equal Identity.encode_component(0.0), Identity.encode_component(-0.0)
    refute_equal Identity.encode_component([ "ab", "c" ]), Identity.encode_component([ "a", "bc" ])
    refute_equal Identity.encode_component([ "a", "" ]), Identity.encode_component([ "a" ])
  end

  test "a string is hashed as its UTF-8 bytes, whatever its Ruby encoding" do
    assert_equal Identity.encode_component("Zürich"), Identity.encode_component("Zürich".encode("ISO-8859-1"))
  end

  test "bytes that are not valid UTF-8 cannot identify a fact" do
    [ "\xFF".dup.force_encoding("UTF-8"), "\xFF".b ].each do |value|
      assert_raises(EventRail::PublicationError, value.inspect) { fact(identity: [ value ]) }
    end
  end

  test "the two rules never hash the same input" do
    fact_tag, execution_tag = Identity.encode_component("fact"), Identity.encode_component("execution")

    refute fact_tag.start_with?(execution_tag)
    refute execution_tag.start_with?(fact_tag)
    IdentityVectors::ALL.each do |vector|
      assert vector.encoded.start_with?(vector.rule == :fact ? fact_tag : execution_tag), "#{vector.name} starts with its rule's tag"
    end
  end

  test "every component of a fact changes its ID, and nothing else is an input" do
    base = fact(identity: [ "o-1" ])

    refute_equal base, fact(source: "other.orders", identity: [ "o-1" ])
    refute_equal base, fact(event_type: "orders.order_shipped", identity: [ "o-1" ])
    refute_equal base, fact(identity: [ "o-2" ])
    refute_equal base, fact(identity: [ "o-1", "line-1" ])
  end

  test "every component of an execution changes its ID" do
    base = execution

    refute_equal base, execution(source: "other.orders")
    refute_equal base, execution(job_class: "Orders::OtherJob")
    refute_equal base, execution(scope: "job-2")
    refute_equal base, execution(scope: [ "other.payments", "job-1" ])
    refute_equal base, execution(event_type: "orders.order_shipped")
    refute_equal base, execution(version: 2)
  end

  test "a fact's identity must be a list" do
    assert_raises(ArgumentError) { Identity.fact(source: "acme.orders", event_type: "orders.order_placed", identity: "o-1") }
  end

  test "a structured or null component cannot identify a fact" do
    [ [ nil ], [ [ "a" ] ], [ { "a" => 1 } ], [ Float::INFINITY ], [ Float::NAN ] ].each do |identity|
      assert_raises(EventRail::PublicationError, "#{identity.inspect} must be rejected") { fact(identity: identity) }
    end
  end

  test "a DateTime component is refused rather than silently narrowed" do
    assert_raises(EventRail::PublicationError) { fact(identity: [ DateTime.new(2026, 9, 1) ]) }
  end

  private
    def fact(source: "acme.orders", event_type: "orders.order_placed", identity:)
      Identity.fact(source: source, event_type: event_type, identity: identity)
    end

    def execution(source: "acme.orders", job_class: "Orders::PlaceOrderJob", scope: "job-1", event_type: "orders.order_placed", version: 1)
      Identity.execution(source: source, job_class: job_class, scope: scope, event_type: event_type, version: version)
    end

    def encoded(vector)
      inputs = vector.inputs
      if vector.rule == :fact
        Identity.encode([ "fact", inputs[:source], inputs[:event_type], inputs[:identity] ])
      else
        Identity.encode([ "execution", inputs[:source], inputs[:job_class], inputs[:scope], inputs[:event_type], inputs[:version], Identity::SINGLETON ])
      end
    end

    def derived(vector)
      vector.rule == :fact ? Identity.fact(**vector.inputs) : Identity.execution(**vector.inputs)
    end
end
