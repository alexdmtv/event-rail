require "test_helper"

Registry.reopen do
  module PublishFixtures
    class Placed < EventRail::Event
      event_type "tests.publish_placed"
      version 1
      default_source "acme.orders"

      attribute :order_id, :string
      identity_by :order_id
    end

    class Silent < EventRail::Event
      event_type "tests.publish_silent"
      version 1
      default_source "acme.orders"

      attribute :order_id, :string
      identity_by :order_id
    end

    class Base < ActiveJob::Base
      include EventRail::JobContext
    end

    class First < Base
      subscribes_to Placed

      def perform(event)
        event
      end
    end

    class Second < Base
      subscribes_to Placed

      def perform(event)
        event
      end
    end

    # Aborts its own enqueue, the way an application's uniqueness, concurrency, or
    # feature-flag guard does.
    class Aborting < Base
      subscribes_to Placed

      class << self
        attr_accessor :abort
      end
      self.abort = false

      before_enqueue { throw :abort if Aborting.abort }

      def perform(event)
        event
      end
    end
  end
end

Registry.prepare

class PublishTest < ActiveSupport::TestCase
  setup do
    EventRail::Current.reset
    PublishFixtures::Aborting.abort = false
  end

  teardown { EventRail::Current.reset }

  # --- 6.1 fanout through individual perform_later ------------------------------

  test "publishing with no subscribers is a successful zero-delivery publication" do
    publication = EventRail.publish(PublishFixtures::Silent.new(order_id: "o-1"))

    assert_predicate publication.event, :stamped?
    assert_empty publication.accepted_subscribers
    assert_empty publication.skipped_subscribers
    assert_equal 0, publication.subscriber_count
    assert_empty enqueued_jobs
  end

  test "publishing enqueues every declared subscriber individually" do
    publication = EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))

    assert_equal(
      [ PublishFixtures::Aborting, PublishFixtures::First, PublishFixtures::Second ],
      publication.accepted_subscribers.sort_by(&:name)
    )
    assert_equal 3, enqueued_jobs.length
    assert_equal 3, publication.subscriber_count
  end

  test "the stamped event reaches each subscriber with its metadata intact" do
    publication = EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))
    event = publication.event

    perform_enqueued_jobs

    assert_equal 3, performed_jobs.length
    performed_jobs.each do |job_data|
      delivered = ActiveJob::Base.deserialize(job_data)
      delivered.send(:deserialize_arguments_if_needed)

      assert_equal event, delivered.arguments.first,
        "the event must survive the queue as the same value, metadata included"
    end
  end

  test "publication never uses bulk enqueue" do
    called = false
    ActiveJob.stub(:perform_all_later, ->(*) { called = true }) do
      EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))
    end

    refute called,
      "bulk enqueue skips each job's own enqueue callbacks on several adapters, which this design " \
      "promises stay authoritative"
  end

  # --- 6.2 three enqueue outcomes -----------------------------------------------

  test "a subscriber aborting its own enqueue is skipped, not a failure" do
    PublishFixtures::Aborting.abort = true

    publication = EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))

    assert_equal [ PublishFixtures::Aborting ], publication.skipped_subscribers
    assert_equal(
      [ PublishFixtures::First, PublishFixtures::Second ],
      publication.accepted_subscribers.sort_by(&:name)
    )
    assert_equal 2, enqueued_jobs.length, "the remaining subscribers must still be enqueued"
  end

  test "an adapter enqueue error is a fault that names what already happened" do
    error = assert_raises(EventRail::EnqueueError) do
      with_failing_adapter(PublishFixtures::Second) do
        EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))
      end
    end

    assert_equal PublishFixtures::Second, error.failed_subscriber
    assert_predicate error.event, :stamped?
    assert_instance_of ActiveJob::EnqueueError, error.cause
    assert_includes error.accepted_subscribers, PublishFixtures::First
  end

  test "a raised enqueue exception is a fault that preserves its cause" do
    error = assert_raises(EventRail::EnqueueError) do
      with_raising_adapter(PublishFixtures::Second) do
        EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))
      end
    end

    assert_equal PublishFixtures::Second, error.failed_subscriber
    assert_instance_of RuntimeError, error.cause
  end

  # --- 6.3 partial fanout and retry ---------------------------------------------

  test "a failed fanout is retried complete in the same execution under the same event ID" do
    in_job do
      first_attempt = assert_raises(EventRail::EnqueueError) do
        with_failing_adapter(PublishFixtures::Second) do
          EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))
        end
      end
      stamped_id = first_attempt.event.id
      clear_enqueued_jobs

      publication = EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))

      assert_equal stamped_id, publication.event.id
      assert_equal 3, publication.accepted_subscribers.length,
        "the retry must repeat complete fanout, so an earlier subscriber may see a duplicate"
    end
  end

  test "repeated failures remain retryable and only a second success is a duplicate" do
    in_job do
      2.times do
        assert_raises(EventRail::EnqueueError) do
          with_failing_adapter(PublishFixtures::Second) do
            EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))
          end
        end
      end

      EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))

      assert_raises(EventRail::DuplicatePublicationError) do
        EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))
      end
    end
  end

  test "a later job attempt repeats fanout with the identity its scope derives" do
    ids = 2.times.map do
      in_job(scope: "job-1") { EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1")).event.id }
    end

    assert_equal 1, ids.uniq.length, "every duplicate must carry the same event ID"
  end

  # --- 6.4 enqueue callbacks and ordering ---------------------------------------

  test "each subscriber's own enqueue callbacks run" do
    ran = []
    PublishFixtures::First.before_enqueue { ran << :first }
    PublishFixtures::Second.before_enqueue { ran << :second }

    EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))

    assert_equal [ :first, :second ], ran.sort
  end

  test "no enqueue order is promised, only that every subscriber is reached" do
    publication = EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))

    assert_equal(
      Registry.snapshot.subscribers_for(PublishFixtures::Placed).sort_by(&:name),
      (publication.accepted_subscribers + publication.skipped_subscribers).sort_by(&:name)
    )
  end

  # --- 6.5 replay-safe publishers ------------------------------------------------

  test "a publisher that already applied its state transition can still repair fanout on retry" do
    # The shape a replay-safe publisher documents: the transition is idempotent, so the
    # retry skips it, but publication is attempted unconditionally and repairs itself.
    transitioned = 0
    publish_attempt = lambda do
      transitioned += 1 if transitioned.zero?
      EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))
    end

    in_job do
      assert_raises(EventRail::EnqueueError) do
        with_failing_adapter(PublishFixtures::Second) do
          transitioned += 1 if transitioned.zero?
          EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))
        end
      end

      publication = publish_attempt.call

      assert_equal 1, transitioned, "an idempotent transition must not be applied twice"
      assert_equal 3, publication.accepted_subscribers.length
    end
  end

  # --- notifications -------------------------------------------------------------

  test "publication emits a data-safe notification carrying accepted and skipped counts" do
    PublishFixtures::Aborting.abort = true
    payloads = capture_notifications("publish.event_rail") do
      EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))
    end

    payload = payloads.sole

    assert_equal "tests.publish_placed", payload.fetch(:event_type)
    assert_equal 1, payload.fetch(:event_version)
    assert_equal "acme.orders", payload.fetch(:source)
    assert_equal 3, payload.fetch(:subscriber_count)
    assert_equal 2, payload.fetch(:accepted)
    assert_equal 1, payload.fetch(:skipped)
    refute_includes payload.keys, :order_id
    refute_includes payload.keys, :extensions
  end

  test "each enqueue reports its outcome, and a fault arrives through Rails' exception keys" do
    PublishFixtures::Aborting.abort = true
    payloads = capture_notifications("enqueue_subscriber.event_rail") do
      EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))
    end

    outcomes = payloads.to_h { |payload| [ payload.fetch(:job_class), payload.fetch(:outcome) ] }

    assert_equal(
      {
        "PublishFixtures::Aborting" => "skipped",
        "PublishFixtures::First" => "accepted",
        "PublishFixtures::Second" => "accepted"
      },
      outcomes
    )

    failed = capture_notifications("enqueue_subscriber.event_rail") do
      assert_raises(EventRail::EnqueueError) do
        with_failing_adapter(PublishFixtures::Second) do
          EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))
        end
      end
    end

    fault = failed.find { |payload| payload.fetch(:job_class) == "PublishFixtures::Second" }

    assert_equal "failed", fault.fetch(:outcome)
    assert_kind_of EventRail::EnqueueError, fault.fetch(:exception_object)
  end

  test "a raising notification handler follows normal Rails semantics" do
    subscription = ActiveSupport::Notifications.subscribe("publish.event_rail") { raise "handler boom" }

    assert_raises(RuntimeError) { EventRail.publish(PublishFixtures::Silent.new(order_id: "o-1")) }
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  test "a subscriber execution emits its own notification" do
    EventRail.publish(PublishFixtures::Placed.new(order_id: "o-1"))

    payloads = capture_notifications("perform_subscriber.event_rail") do
      perform_enqueued_jobs(only: PublishFixtures::First)
    end

    assert_equal "PublishFixtures::First", payloads.sole.fetch(:job_class)
    assert_equal "tests.publish_placed", payloads.sole.fetch(:event_type)
  end

  private
    def in_job(job_class: "Orders::PlaceOrderJob", scope: "job-1")
      execution = EventRailInternal::Execution.new(
        job_class: job_class, scope: scope, started_at: Time.utc(2026, 9, 1, 10, 0, 0)
      )
      EventRail::Current.message_id = scope
      EventRail::Current.correlation_id = "corr-1"
      EventRailInternal::Execution.wrap(execution) { yield execution }
    end

    def capture_notifications(name)
      payloads = []
      subscription = ActiveSupport::Notifications.subscribe(name) do |*args|
        payloads << ActiveSupport::Notifications::Event.new(*args).payload
      end
      yield
      payloads
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    # An adapter that reports failure the way Active Job's contract says: the job is
    # marked not successfully enqueued and carries the adapter's error.
    def with_failing_adapter(job_class, &block)
      job_class.stub(:perform_later, failing_enqueue(job_class), &block)
    end

    def failing_enqueue(job_class)
      lambda do |*arguments, &block|
        job = job_class.new(*arguments)
        job.successfully_enqueued = false
        job.enqueue_error = ActiveJob::EnqueueError.new("adapter refused the job")
        block&.call(job)
        false
      end
    end

    def with_raising_adapter(job_class, &block)
      job_class.stub(:perform_later, ->(*) { raise "adapter exploded" }, &block)
    end
end
