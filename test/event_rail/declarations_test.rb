require "test_helper"

class DeclarationsTest < ActiveSupport::TestCase
  test "rejects unknown local input and reserved payload declarations" do
    event_class = build_event_class("tests.unknown", 1) do
      attribute :name, :string
    end

    assert_raises(EventRail::InvalidEvent) { event_class.new(name: "valid", extra: true) }

    %i[id metadata occurred_at correlation_id causation_id extensions attributes event_type version].each do |name|
      assert_raises(EventRail::DeclarationError) do
        build_event_class("tests.reserved.#{name}", 1) { attribute name, :string }
      end
    end
  end

  test "rejects callable defaults and accepts frozen literal defaults" do
    assert_raises(EventRail::DeclarationError) do
      Class.new(EventRail::Data) { attribute :value, :string, default: -> { "dynamic" } }
    end

    data_class = Class.new(EventRail::Data) do
      attribute :settings, default: { "modes" => [ "fast" ] }
    end
    first = data_class.new
    second = data_class.new

    assert_equal({ "modes" => [ "fast" ] }, first.settings)
    refute_same first.settings, second.settings
    assert_raises(FrozenError) { first.settings.fetch("modes") << "slow" }
  end

  test "requires explicit contracts and validates identity declarations" do
    assert_raises(EventRail::InvalidContract) { Class.new(EventRail::Event).new }

    undeclared = build_event_class("tests.undeclared_identity", 1) { identity_by :missing }
    assert_raises(EventRail::InvalidContract) { undeclared.new }

    raw_identity = build_event_class("tests.raw_identity", 1) do
      attribute :details
      identity_by :details
    end
    assert_raises(EventRail::InvalidContract) { raw_identity.new(details: "not typed") }

    array_identity = build_event_class("tests.array_identity", 1) do
      attribute :ids, :string, array: true
      identity_by :ids
    end
    assert_raises(EventRail::InvalidContract) { array_identity.new(ids: [ "1" ]) }
  end

  test "does not inherit identity declarations into another concrete contract" do
    parent = build_event_class("tests.identity_parent", 1) do
      attribute :aggregate_id, :string
      identity_by :aggregate_id
    end
    child = Class.new(parent) do
      event_type "tests.identity_child"
      version 1
    end

    assert_equal [ "aggregate_id" ], parent.identity_by
    assert_empty child.identity_by
    assert child.new(aggregate_id: "1")
  end

  test "inherits arbitrary bounded sources without imposing URI syntax" do
    base = Class.new(EventRail::Event) { default_source "orders team / primary" }
    event_class = Class.new(base) do
      event_type "tests.source"
      version 1
      attribute :id_value, :string
    end
    event = event_class.new(id_value: "1")
    stamped = event.__stamp__(id: "external-id", correlation_id: "root", occurred_at: Time.now.utc)

    assert_equal "orders team / primary", stamped.source
  end

  test "rejects invalid source declarations early" do
    assert_raises(EventRail::DeclarationError) { Class.new(EventRail::Event) { default_source "" } }
    assert_raises(EventRail::DeclarationError) do
      Class.new(EventRail::Event) { default_source "s" * (EventRail::Limits::MAX_SOURCE_BYTES + 1) }
    end
  end

  test "rejects duplicate event type and version pairs" do
    first = build_event_class("tests.duplicate", 1)
    second = build_event_class("tests.duplicate", 1)

    error = assert_raises(EventRail::DuplicateContractError) do
      EventRail.const_get(:Internal, false)::ContractIndex.build([ first, second ])
    end

    assert_equal "tests.duplicate", error.event_type
    assert_equal 1, error.version
    assert_equal [ first, second ], error.event_classes
  end

  test "requires a source when stamping" do
    event_class = Class.new(EventRail::Event) do
      event_type "tests.no_source"
      version 1
    end
    event = event_class.new

    assert_raises(EventRail::InvalidMetadata) do
      event.__stamp__(id: "id", correlation_id: "correlation", occurred_at: Time.now.utc)
    end
  end

  private
    def build_event_class(type, version, &definition)
      Class.new(EventRail::Event) do
        event_type type
        self.version version
        default_source "tests"
        class_eval(&definition) if definition
      end
    end
end
