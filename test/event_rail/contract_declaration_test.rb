require "test_helper"

# The sealing rule applied to event contracts. Subscriptions have followed it since v1; this
# is the half the implementation was missing, which let a concrete event class outside
# `app/events` publish and serialize cleanly and fail only in the worker.

# Fixtures are held outside the test class, so `const_set` does not define a constant that
# later lookups inside the class body would shadow.
module ContractFixtureHolder
end

class ContractDeclarationTest < ActiveSupport::TestCase
  teardown { EventRail::Current.reset }

  # --- the rule -----------------------------------------------------------------

  test "a named event class declaring its type after sealing is rejected" do
    error = assert_raises(EventRail::DeclarationError) { declare_in_place(:LateByType) { event_type "tests.late" } }

    assert_match(/declared an event contract after EventRail finished preparing/, error.message)
    assert_match(/a worker could not reconstruct it from the queue/, error.message)
  end

  test "a named event class declaring its version after sealing is rejected" do
    error = assert_raises(EventRail::DeclarationError) { declare_in_place(:LateByVersion) { version 2 } }

    assert_match(/declared an event contract after EventRail finished preparing/, error.message)
  end

  test "the rejection names the file and line of the declaration" do
    error = assert_raises(EventRail::DeclarationError) { declare_in_place(:LateWithLocation) { event_type "tests.late2" } }

    assert_match(/contract_declaration_test\.rb:\d+/, error.message)
  end

  test "the rejection offers a discovery root as the fix" do
    error = assert_raises(EventRail::DeclarationError) { declare_in_place(:LateWithFix) { event_type "tests.late3" } }

    assert_match(/app\/events/, error.message)
    assert_match(/EventRail::TestHelper\.declare/, error.message)
  end

  test "an unnamed event class is exempt" do
    # It could never enter the contract index: `build_contracts` selects through the constant
    # a class's name denotes, and an unnamed class has none. Checking it would reject every
    # inline event definition in a test suite for nothing.
    anonymous = Class.new(EventRail::Event) do
      event_type "tests.anonymous_contract"
      version 1
      default_source "tests"
    end

    assert_equal "tests.anonymous_contract", anonymous.event_type
    assert_nil Registry.snapshot.event_class_for("tests.anonymous_contract", 1)
  end

  test "an abstract base declaring neither type nor version still loads after sealing" do
    base = Class.new(EventRail::Event) do
      default_source "tests"
      attribute :order_id, :string
    end
    ContractFixtureHolder.const_set(:AbstractBase, base)

    refute_predicate base, :concrete?
    assert Registry.prepare, "an abstract base contributes no contract and must not be rejected"
  ensure
    ContractFixtureHolder.send(:remove_const, :AbstractBase)
  end

  # --- reading is not declaring -------------------------------------------------

  test "reading either attribute on a sealed registry does not raise" do
    # The one subtle part of the implementation: both methods are reader/writer pairs, and a
    # check placed before the sentinel branch would fire on every read. Reads happen on every
    # snapshot build, through `concrete?`.
    assert_equal "orders.order_placed", Orders::OrderPlaced.event_type
    assert_equal 1, Orders::OrderPlaced.version
    assert_predicate Orders::OrderPlaced, :concrete?
    assert Registry.prepare
  end

  test "a malformed value still gets its own error rather than the timing one" do
    error = assert_raises(EventRail::DeclarationError) { declare_in_place(:BadValue) { event_type "" } }

    assert_match(/non-empty valid string/, error.message)
  end

  # --- an event registered only because a subscriber names it ---------------------

  test "an event outside every discovery root is registered when a subscriber names it" do
    # Preserved deliberately: `Inventory::RecordDepletionJob` lives in app/jobs and names
    # `Inventory::StockDepleted`, which lives in app/models, so the macro autoloads it while
    # preparation is still building.
    assert_equal(
      Inventory::StockDepleted,
      Registry.snapshot.event_class_for("inventory.stock_depleted", 1)
    )
    assert_includes Registry.snapshot.subscribers_for(Inventory::StockDepleted), Inventory::RecordDepletionJob
  end

  # --- the five states ----------------------------------------------------------

  # The unprepared row -- snapshot nil, everything accepted -- cannot be observed in this
  # process, where the host application is already initialized. It is asserted in
  # `reloading_test.rb`, in a child that stops short of `initialize!`.

  test "the registry accepts a declaration while preparation is building" do
    Registry.reopen { assert_nothing_raised { declare_in_place(:WhileBuilding) { event_type "tests.while_building" } } }
  ensure
    remove_fixture(:WhileBuilding)
  end

  test "the registry accepts a declaration while a reload is in progress" do
    Registry.instance_variable_set(:@reloading, true)

    assert_nothing_raised { declare_in_place(:WhileReloading) { event_type "tests.while_reloading" } }
  ensure
    Registry.instance_variable_set(:@reloading, false)
    remove_fixture(:WhileReloading)
  end

  test "the registry accepts a declaration inside a test declaration window" do
    EventRail::TestHelper.declare do
      ContractFixtureHolder.const_set(:InWindow, Class.new(EventRail::Event) do
        event_type "tests.in_window"
        version 1
        default_source "tests"
      end)
    end

    assert_equal(
      ContractFixtureHolder::InWindow,
      Registry.snapshot.event_class_for("tests.in_window", 1)
    )
  ensure
    remove_fixture(:InWindow)
  end

  test "a window opened during a reload behaves as a window" do
    Registry.instance_variable_set(:@reloading, true)

    assert_nothing_raised do
      EventRail::TestHelper.declare do
        ContractFixtureHolder.const_set(:WindowInReload, Class.new(EventRail::Event) do
          event_type "tests.window_in_reload"
          version 1
          default_source "tests"
        end)
      end
    end
  ensure
    Registry.instance_variable_set(:@reloading, false)
    remove_fixture(:WindowInReload)
  end

  test "the registry rejects a declaration once sealed" do
    assert_raises(EventRail::DeclarationError) { declare_in_place(:WhileSealed) { event_type "tests.while_sealed" } }
  end

  private
    # `const_set` names the class only after its block has run, so the writer has to be
    # called on an already-named class for the rule to apply at all.
    def declare_in_place(name, &block)
      ContractFixtureHolder.const_set(name, Class.new(EventRail::Event) do
        default_source "tests"
        attribute :order_id, :string
      end)
      ContractFixtureHolder.const_get(name).class_eval(&block)
    end

    def remove_fixture(name)
      ContractFixtureHolder.send(:remove_const, name) if ContractFixtureHolder.const_defined?(name, false)
      Registry.prepare
    end
end
