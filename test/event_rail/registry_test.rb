require "test_helper"

# Subscriber fixtures are declared after the host application has already been
# prepared, which is exactly the case the registry refuses by default. `reopen` is the
# same door preparation itself uses.
Registry.reopen do
  module RegistryFixtures
    class Placed < EventRail::Event
      event_type "tests.registry_placed"
      version 1
      default_source "tests"

      attribute :order_id, :string
    end

    class Shipped < EventRail::Event
      event_type "tests.registry_shipped"
      version 1
      default_source "tests"

      attribute :order_id, :string
    end

    class Base < ActiveJob::Base
      include EventRail::JobContext
    end

    class OnPlaced < Base
      subscribes_to Placed
      queue_as :critical
      retry_on RuntimeError, attempts: 7

      class << self
        attr_accessor :handled
      end
      self.handled = []

      def perform(event)
        self.class.handled << {
          event: event,
          message_id: EventRail::Current.message_id,
          correlation_id: EventRail::Current.correlation_id,
          causation_id: EventRail::Current.causation_id,
          extensions: EventRail::Current.extensions,
          execution: EventRailInternal::Execution.current
        }
      end
    end

    class OnBoth < Base
      subscribes_to Placed, Shipped

      def perform(event)
        event
      end
    end

    class WithoutJobContext < ActiveJob::Base
      def perform(event)
        event
      end
    end

    class WithSubclass < Base
      def perform(event)
        event
      end
    end

    # Declares its own subscription and its own perform: inheriting perform from a
    # shared parent would itself make it abstract under the same rule.
    class ConcreteChild < WithSubclass
      def perform(event)
        event
      end
    end

    class NoOwnPerform < Base
    end

    class SplatPerform < Base
      def perform(*events)
        events
      end
    end

    class KeywordPerform < Base
      def perform(event:)
        event
      end
    end
  end
end

# The subclass has to be declared as a subscriber for the inheritance test, and the
# parent must not be, so this pair is set up outside the shared fixture block.
Registry.reopen { RegistryFixtures::ConcreteChild.subscribes_to RegistryFixtures::Shipped }

class RegistryTest < ActiveSupport::TestCase
  setup do
    EventRail::Current.reset
    RegistryFixtures::OnPlaced.handled = []
  end

  teardown { EventRail::Current.reset }

  # --- 5.3 discovery across the host and its engines ---------------------------

  test "preparation discovers every event contract and subscriber without an initializer" do
    snapshot = Registry.prepare

    assert_equal Host::ApplicationStarted, snapshot.event_class_for("host.application_started", 1)
    assert_equal Orders::OrderPlaced, snapshot.event_class_for("orders.order_placed", 1)
    assert_equal Billing::InvoiceIssued, snapshot.event_class_for("billing.invoice_issued", 1)

    assert_equal [ Host::AuditApplicationStartedJob ], snapshot.subscribers_for(Host::ApplicationStarted)
    assert_equal(
      [ Billing::CreateInvoiceJob, Orders::RecordOrderMetricsJob ],
      snapshot.subscribers_for(Orders::OrderPlaced),
      "an engine must be able to subscribe to another engine's event"
    )
  end

  test "an application's own abstract event base is not a registrable contract" do
    base = Class.new(EventRail::Event)

    refute_predicate base, :concrete?
    assert_predicate RegistryFixtures::Placed, :concrete?
  end

  test "a conventional root that is ignored or unmanaged is handled rather than raising" do
    unmanaged = Object.new
    unmanaged.define_singleton_method(:dirs) { [ "/nowhere/app/events", Dir.pwd ] }
    unmanaged.define_singleton_method(:eager_load_dir) { |_dir| raise Zeitwerk::Error, "not managed" }
    autoloaders = Struct.new(:main).new(unmanaged)

    Rails.stub(:autoloaders, autoloaders) do
      assert Registry.prepare, "an unmanaged directory must not fail preparation"
    end

    Registry.prepare
  end

  test "an invalid identity declaration fails preparation rather than first construction" do
    # const_set rather than a `module RegistryFixtures` reopening, which inside a test
    # body would define a second, empty RegistryTest::RegistryFixtures and shadow the
    # real one for every later lookup in this class.
    RegistryFixtures.const_set(:BadIdentity, Class.new(EventRail::Event) do
      event_type "tests.registry_bad_identity"
      version 1
      default_source "tests"

      attribute :order_id, :string
      identity_by :undeclared
    end)

    assert_raises(EventRail::InvalidContract) { Registry.prepare }
  ensure
    RegistryFixtures.send(:remove_const, :BadIdentity)
    Registry.prepare
  end

  # --- 5.1 the pending list, the snapshot, and readiness -----------------------

  test "publication before the first snapshot raises a distinct not-ready error" do
    # The real pending list, not a hardcoded one: every other test file declares its own
    # subscriber fixtures into it, and restoring a guess would silently unregister them.
    pending = Registry.instance_variable_get(:@pending).dup
    Registry.reset!

    assert_raises(EventRail::NotReadyError) { Registry.snapshot }
    refute_predicate Registry, :prepared?
  ensure
    Registry.instance_variable_set(:@pending, pending)
    Registry.prepare
  end

  test "a declaration from non-reloadable code survives repeated rebuilds" do
    3.times { Registry.prepare }

    assert_includes Registry.snapshot.subscribers_for(RegistryFixtures::Placed), RegistryFixtures::OnPlaced
  end

  test "a declaration arriving after the snapshot is sealed raises with the fix" do
    error = assert_raises(EventRail::DeclarationError) do
      Class.new(RegistryFixtures::Base) do
        def self.name
          "RegistryFixtures::TooLate"
        end

        subscribes_to RegistryFixtures::Placed

        def perform(event)
          event
        end
      end
    end

    assert_match(/app\/events/, error.message)
    assert_match(/autoload-once/, error.message)
  end

  test "concurrent readers observe only a complete snapshot" do
    rebuilds = Thread.new { 20.times { Registry.prepare } }

    readers = 4.times.map do
      Thread.new do
        200.times.map do
          snapshot = Registry.snapshot
          Thread.pass
          [ snapshot.frozen?, snapshot.subscribers.frozen?,
            snapshot.subscribers_for(RegistryFixtures::Placed).include?(RegistryFixtures::OnPlaced) ]
        end
      end
    end

    observations = readers.flat_map(&:value)
    rebuilds.join

    assert_equal 800, observations.length
    assert observations.all? { |frozen, subscribers_frozen, found| frozen && subscribers_frozen && found },
      "a reader saw a partially built snapshot"
  end

  # --- 5.2 what a subscriber declaration must look like ------------------------

  test "a subscriber keeps its own queue and retry configuration" do
    assert_equal "critical", RegistryFixtures::OnPlaced.queue_name
    assert_equal [ RegistryFixtures::Placed ], RegistryFixtures::OnPlaced.event_rail_subscriptions
  end

  test "one job may subscribe to several exact event classes" do
    snapshot = Registry.prepare

    assert_includes snapshot.subscribers_for(RegistryFixtures::Placed), RegistryFixtures::OnBoth
    assert_includes snapshot.subscribers_for(RegistryFixtures::Shipped), RegistryFixtures::OnBoth
  end

  test "declarations are not inherited in either direction" do
    assert_empty RegistryFixtures::WithSubclass.event_rail_subscriptions,
      "a parent must not inherit its subclass's declaration"
    assert_equal [ RegistryFixtures::Shipped ], RegistryFixtures::ConcreteChild.event_rail_subscriptions
    assert_empty RegistryFixtures::OnPlaced.subclasses,
      "a concrete subscriber must not be subclassed, which is what makes it abstract"
    refute_includes(
      Registry.prepare.subscribers_for(RegistryFixtures::Shipped), RegistryFixtures::WithSubclass
    )
  end

  test "an event class declared twice in one job body is an error" do
    Registry.reopen do
      assert_raises(EventRail::DeclarationError) do
        Class.new(RegistryFixtures::Base) do
          subscribes_to RegistryFixtures::Placed
          subscribes_to RegistryFixtures::Placed
        end
      end
      assert_raises(EventRail::DeclarationError) do
        Class.new(RegistryFixtures::Base) do
          subscribes_to RegistryFixtures::Placed, RegistryFixtures::Placed
        end
      end
    end
  end

  test "a subscription to something that is not an event class is an error" do
    Registry.reopen do
      [ String, "Orders::OrderPlaced", nil, EventRail::Event ].each do |candidate|
        assert_raises(EventRail::DeclarationError, "#{candidate.inspect} must be rejected") do
          Class.new(RegistryFixtures::Base) { subscribes_to candidate }
        end
      end
      assert_raises(EventRail::DeclarationError) do
        Class.new(RegistryFixtures::Base) { subscribes_to }
      end
    end
  end

  test "preparation rejects an abstract subscriber" do
    assert_preparation_rejects RegistryFixtures::NoOwnPerform, /does not define its own perform/
    assert_preparation_rejects RegistryFixtures::WithSubclass, /has subclasses/
  end

  test "preparation rejects a splat or keyword perform signature" do
    assert_preparation_rejects RegistryFixtures::SplatPerform, /exactly one required positional/
    assert_preparation_rejects RegistryFixtures::KeywordPerform, /exactly one required positional/
  end

  # --- 4.4 required context integration ----------------------------------------

  test "preparation rejects a subscriber that does not propagate logical context" do
    assert_preparation_rejects RegistryFixtures::WithoutJobContext, /include EventRail::JobContext/
  end

  test "an ordinary job that declares nothing is untouched by preparation" do
    Registry.prepare

    refute_predicate ApplicationJob, :event_rail_subscriber?
    refute_includes Registry.snapshot.subscribers.values.flatten, ApplicationJob
  end

  # --- 4.3 subscriber execution context ----------------------------------------

  test "a subscriber's logical message is the delivered event, not its delivery job" do
    event = stamped_event
    perform_subscriber(event)
    handled = RegistryFixtures::OnPlaced.handled.sole

    assert_equal event, handled.fetch(:event)
    assert_equal event.id, handled.fetch(:message_id)
    assert_equal event.correlation_id, handled.fetch(:correlation_id)
    assert_equal event.causation_id, handled.fetch(:causation_id)
    assert_equal event.extensions, handled.fetch(:extensions)
  end

  test "a subscriber's identity scope is the delivered event, so a follow-up is stable" do
    event = stamped_event
    perform_subscriber(event)
    execution = RegistryFixtures::OnPlaced.handled.sole.fetch(:execution)

    assert_equal event.id, execution.scope
    assert_equal "RegistryFixtures::OnPlaced", execution.job_class
    assert_predicate execution, :derives_identity?
  end

  test "execution rejects an argument of an undeclared class before subscriber code runs" do
    [ "not an event", nil, stamped_event(event_class: RegistryFixtures::Shipped) ].each do |argument|
      error = assert_raises(EventRail::UnexpectedEventError) do
        RegistryFixtures::OnPlaced.new(argument).perform_now
      end

      assert_equal RegistryFixtures::OnPlaced, error.job_class
      assert_empty RegistryFixtures::OnPlaced.handled
    end
  end

  test "execution rejects an unpublished proposal of the declared class" do
    proposal = RegistryFixtures::Placed.new(order_id: "o-1")

    error = assert_raises(EventRail::UnexpectedEventError) do
      RegistryFixtures::OnPlaced.new(proposal).perform_now
    end

    assert_match(/unpublished/, error.message)
    assert_empty RegistryFixtures::OnPlaced.handled
  end

  test "execution rejects an unexpected number of arguments" do
    event = stamped_event

    assert_raises(EventRail::UnexpectedEventError) do
      RegistryFixtures::OnPlaced.new(event, "extra").perform_now
    end
  end

  private
    def assert_preparation_rejects(job_class, message)
      Registry.reopen { job_class.subscribes_to RegistryFixtures::Placed }
      error = assert_raises(EventRail::DeclarationError) { Registry.prepare }

      assert_match message, error.message
    ensure
      job_class.instance_variable_set(:@event_rail_subscriptions, [])
      Registry.instance_variable_get(:@pending).delete(job_class)
      Registry.prepare
    end

    def stamped_event(event_class: RegistryFixtures::Placed)
      event_class.send(
        :__reconstruct__,
        data: { "order_id" => "o-1" },
        metadata: EventRail::Metadata.complete(
          id: "evt-#{event_class.name}",
          source: "tests",
          occurred_at: Time.utc(2026, 9, 1),
          correlation_id: "corr-1",
          causation_id: "cause-1",
          extensions: { "tenant" => "acme" }
        )
      )
    end

    def perform_subscriber(event)
      RegistryFixtures::OnPlaced.new(event).perform_now
    end
end
