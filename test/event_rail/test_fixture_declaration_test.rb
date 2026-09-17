require "test_helper"
require "open3"
require "rbconfig"

# The public test door. These fixtures are declared through the door they exercise, which
# is the point: if `declare` did not work, this file would not load.
EventRail::TestHelper.declare do
  module FixtureDoor
    class Placed < EventRail::Event
      event_type "tests.fixture_door_placed"
      version 1
      default_source "tests"

      attribute :order_id, :string
    end

    class Base < ActiveJob::Base
      include EventRail::JobContext
    end

    class AuditJob < Base
      def self.seen = (@seen ||= [])

      subscribes_to Placed

      def perform(event) = self.class.seen << event.order_id
    end

    class SecondJob < Base
      subscribes_to Placed

      def perform(event) = event
    end

    class LiveEventSubscriber < Base
      subscribes_to Orders::OrderPlaced

      def perform(event) = event
    end
  end
end

class TestFixtureDeclarationTest < ActiveSupport::TestCase
  setup { FixtureDoor::AuditJob.seen.clear }
  teardown { EventRail::Current.reset }

  # --- the window ---------------------------------------------------------------

  test "a contract declared in a window is indexed when the window closes" do
    assert_equal FixtureDoor::Placed, Registry.snapshot.event_class_for("tests.fixture_door_placed", 1)
  end

  test "a window-declared event round-trips through Active Job serialization" do
    event = publish_fixture.event

    restored = ActiveJob::Serializers.deserialize(ActiveJob::Serializers.serialize(event))

    assert_equal FixtureDoor::Placed, restored.class
    assert_equal event.id, restored.id
  end

  test "a subscription declared in a window is dormant" do
    assert_empty Registry.snapshot.subscribers_for(FixtureDoor::Placed)
    assert_empty publish_fixture.accepted_subscribers
  end

  test "a duplicate fixture contract stays rejected on every later rebuild" do
    FixtureDoor.const_set(:Duplicate, Class.new(EventRail::Event) do
      default_source "tests"
      attribute :order_id, :string
    end)

    # Declared outside a window would raise for lateness, so the writer runs inside one --
    # and closing the window is where the duplicate is caught.
    assert_raises(EventRail::DuplicateContractError) do
      EventRail::TestHelper.declare do
        FixtureDoor::Duplicate.event_type "tests.fixture_door_placed"
        FixtureDoor::Duplicate.version 1
      end
    end

    assert_raises(
      EventRail::DuplicateContractError,
      "a class cannot be unloaded, so the duplicate poisons every later rebuild"
    ) { Registry.prepare }
  ensure
    FixtureDoor.send(:remove_const, :Duplicate)
    Registry.prepare
  end

  test "closing a window does not disturb the live registry" do
    before = Registry.snapshot.subscribers_for(Orders::OrderPlaced)

    EventRail::TestHelper.declare do
      module FixtureDoorLater
        class Unrelated < ActiveJob::Base
          include EventRail::JobContext

          subscribes_to Orders::OrderPlaced

          def perform(event) = event
        end
      end
    end

    assert_equal before, Registry.snapshot.subscribers_for(Orders::OrderPlaced)
  end

  # --- activation ---------------------------------------------------------------

  test "an activated fixture receives the event" do
    with_subscribers(FixtureDoor::AuditJob) do
      publication = publish_fixture

      assert_enqueued_with job: FixtureDoor::AuditJob, args: [ publication.event ]
      perform_enqueued_jobs only: FixtureDoor::AuditJob
    end

    assert_equal [ "o-1" ], FixtureDoor::AuditJob.seen
  end

  test "the previous registry is restored after the block" do
    with_subscribers(FixtureDoor::AuditJob) { publish_fixture }

    assert_empty publish_fixture.accepted_subscribers
  end

  test "the previous registry is restored when the block raises" do
    error = assert_raises(RuntimeError) do
      with_subscribers(FixtureDoor::AuditJob) { raise "boom" }
    end

    assert_equal "boom", error.message
    assert_empty publish_fixture.accepted_subscribers
  end

  test "nested activations are additive and unwind one level at a time" do
    with_subscribers(FixtureDoor::AuditJob) do
      with_subscribers(FixtureDoor::SecondJob) do
        assert_equal(
          [ FixtureDoor::AuditJob, FixtureDoor::SecondJob ],
          publish_fixture.accepted_subscribers.sort_by(&:name)
        )
      end

      assert_equal [ FixtureDoor::AuditJob ], publish_fixture.accepted_subscribers
    end
  end

  test "several fixtures activate in one call" do
    with_subscribers(FixtureDoor::AuditJob, FixtureDoor::SecondJob) do
      assert_equal 2, publish_fixture.accepted_subscribers.length
    end
  end

  test "a discovered subscriber and an activated fixture both receive an event" do
    with_subscribers(FixtureDoor::LiveEventSubscriber) do
      accepted = EventRail.publish(Orders::OrderPlaced.new(order_id: "o-9")).accepted_subscribers

      assert_includes accepted, FixtureDoor::LiveEventSubscriber
      assert_includes accepted, Billing::CreateInvoiceJob
    end
  end

  test "activation validates the fixture the way preparation does" do
    EventRail::TestHelper.declare do
      module FixtureDoorAbstract
        class NoOwnPerform < ActiveJob::Base
          include EventRail::JobContext

          subscribes_to FixtureDoor::Placed
        end
      end
    end

    error = assert_raises(EventRail::DeclarationError) do
      with_subscribers(FixtureDoorAbstract::NoOwnPerform) { }
    end

    assert_match(/does not define its own perform/, error.message)
  end

  # --- rejections ---------------------------------------------------------------

  test "activating a subscriber that was never declared in a window is rejected" do
    undeclared = Class.new(FixtureDoor::Base) do
      def self.name = "FixtureDoorUndeclared"
      def perform(event) = event
    end

    error = assert_raises(ArgumentError) { with_subscribers(undeclared) { } }

    assert_match(/was not declared inside EventRail::TestHelper.declare/, error.message)
  end

  test "activating an unnameable class is rejected" do
    error = assert_raises(ArgumentError) { with_subscribers(Class.new(FixtureDoor::Base)) { } }

    assert_match(/cannot enqueue a job it cannot name/, error.message)
  end

  test "activating a subscriber discovered at boot is rejected" do
    error = assert_raises(ArgumentError) { with_subscribers(Billing::CreateInvoiceJob) { } }

    assert_match(/already a live subscriber/, error.message)
  end

  test "a declaration window opened inside an activation is refused" do
    error = assert_raises(ArgumentError) do
      with_subscribers(FixtureDoor::AuditJob) { EventRail::TestHelper.declare { } }
    end

    assert_match(/cannot be opened inside with_subscribers/, error.message)
  end

  # --- the sealing rule is unchanged outside a window ----------------------------

  test "a subscription declared outside a window still fails" do
    assert_raises(EventRail::DeclarationError) do
      Class.new(FixtureDoor::Base) do
        def self.name = "FixtureDoorLateSubscriber"

        subscribes_to FixtureDoor::Placed

        def perform(event) = event
      end
    end
  end

  test "requiring the helper does not make the door implicit" do
    refute Registry.instance_variable_get(:@window),
      "no window may be left open once a declaration block has returned"
  end

  # --- the facility is opt-in ---------------------------------------------------

  test "requiring the library alone does not load the test helper" do
    script = <<~'RUBY'
      require "event_rail"
      puts EventRail.const_defined?(:TestHelper)
    RUBY

    output, error, status = Open3.capture3(
      RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script
    )

    assert status.success?, "boot failed: #{error}"
    assert_equal "false", output.strip
  end

  test "including the helper adds with_subscribers and not declare" do
    assert_includes EventRail::TestHelper.instance_methods(false), :with_subscribers
    assert_equal [ :with_subscribers ], EventRail::TestHelper.instance_methods(false)
    assert_respond_to EventRail::TestHelper, :declare
  end

  # --- documented limits --------------------------------------------------------

  test "the thread-parallelisation limit is documented where the facility is" do
    source = File.read(File.expand_path("../../lib/event_rail/test_helper.rb", __dir__))

    assert_includes source, "parallelize(with: :threads)"
    assert_match(/[Pp]rocess-based\s+.{0,40}parallelisation/m, source)
  end

  private
    def publish_fixture(order_id: "o-1")
      EventRail.publish(FixtureDoor::Placed.new(order_id: order_id))
    end
end
