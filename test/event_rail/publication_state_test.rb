require "test_helper"

module PublicationFixtures
  class OrderPlaced < EventRail::Event
    event_type "tests.pub_order_placed"
    version 1
    default_source "acme.orders"

    attribute :order_id, :string
    attribute :note, :string
    identity_by :order_id
  end

  class Keyless < EventRail::Event
    event_type "tests.pub_keyless"
    version 1
    default_source "acme.orders"

    attribute :note, :string
  end

  class Sourceless < EventRail::Event
    event_type "tests.pub_sourceless"
    version 1

    attribute :note, :string
  end
end

class PublicationStateTest < ActiveSupport::TestCase
  Publication = EventRailInternal::Publication
  Execution = EventRailInternal::Execution

  setup { EventRail::Current.reset }
  teardown { EventRail::Current.reset }

  EXECUTION_START = Time.utc(2026, 9, 1, 10, 0, 0)

  def in_job(job_class: "Orders::PlaceOrderJob", scope: "job-1", started_at: EXECUTION_START)
    execution = Execution.new(job_class: job_class, scope: scope, started_at: started_at)
    EventRail::Current.message_id = scope
    EventRail::Current.correlation_id = "corr-1"
    Execution.wrap(execution) { yield execution }
  end

  # --- 3.3 logical identity selection ------------------------------------------

  test "a declared identity needs no call-site key and survives a retry" do
    first = in_job { Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1")).event }
    again = in_job { Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1")).event }

    assert_equal first.id, again.id
    assert_equal "acme.orders", first.source
  end

  test "distinct declared identity values derive distinct identities in one execution" do
    ids = in_job do
      [ "o-1", "o-2" ].map { |id| Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: id)).event.id }
    end

    assert_equal 2, ids.uniq.length
  end

  test "distinct explicit keys distinguish repeated facts of one type" do
    ids = in_job do
      [ "a", "b" ].map { |key| Publication.prepare(PublicationFixtures::Keyless.new(note: "n"), key: key).event.id }
    end

    assert_equal 2, ids.uniq.length
  end

  test "a keyless singleton publication is stable across retries of the same execution scope" do
    first = in_job { Publication.prepare(PublicationFixtures::Keyless.new(note: "n")).event }
    again = in_job { Publication.prepare(PublicationFixtures::Keyless.new(note: "n")).event }

    assert_equal first.id, again.id
  end

  test "a different execution scope derives a different identity" do
    first = in_job(scope: "job-1") { Publication.prepare(PublicationFixtures::Keyless.new(note: "n")).event }
    other = in_job(scope: "job-2") { Publication.prepare(PublicationFixtures::Keyless.new(note: "n")).event }

    refute_equal first.id, other.id
  end

  test "an explicit key must be a string so one value cannot derive two identities" do
    in_job do
      assert_raises(EventRail::PublicationError) do
        Publication.prepare(PublicationFixtures::Keyless.new(note: "n"), key: 1)
      end
      assert_raises(EventRail::PublicationError) do
        Publication.prepare(PublicationFixtures::Keyless.new(note: "n"), key: "")
      end
    end
  end

  test "publication requires a source" do
    in_job do
      assert_raises(EventRail::InvalidMetadata) do
        Publication.prepare(PublicationFixtures::Sourceless.new(note: "n"))
      end
    end
  end

  test "publication outside a job execution assigns a random identity" do
    one = Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1")).event
    two = Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1")).event

    refute_equal one.id, two.id
    assert_match(/\A[0-9a-f-]{36}\z/, one.id)
  end

  test "a boundary block still assigns a random identity" do
    ids = EventRail.with_context(message_id: "req-1") do
      2.times.map { Publication.prepare(PublicationFixtures::Keyless.new(note: "n")).event.id }
    end

    assert_equal 2, ids.uniq.length
  end

  # --- relaying an already-stamped event ---------------------------------------

  test "a relayed external event keeps its identity, source, time, and extensions" do
    relayed = in_job { Publication.prepare(external_event).event }

    assert_equal "ext-1", relayed.id
    assert_equal "partner.billing", relayed.source
    assert_equal Time.utc(2026, 8, 1), relayed.occurred_at
    assert_equal "ext-corr", relayed.correlation_id
    assert_equal({ "region" => "eu" }, relayed.extensions)
  end

  test "a relay does not merge the relaying application's own extensions" do
    relayed = in_job do
      EventRail::Current.extensions = { "tenant" => "acme" }.freeze
      Publication.prepare(external_event).event
    end

    assert_equal({ "region" => "eu" }, relayed.extensions)
  end

  test "a relay records the local message as its cause only when it carries none" do
    without_cause = in_job { Publication.prepare(external_event).event }
    assert_equal "job-1", without_cause.causation_id

    with_cause = in_job { Publication.prepare(external_event(causation_id: "ext-cause")).event }
    assert_equal "ext-cause", with_cause.causation_id
  end

  test "a publication key cannot apply to an event that already carries an identity" do
    in_job do
      assert_raises(EventRail::PublicationError) { Publication.prepare(external_event, key: "k") }
    end
  end

  # --- 3.4 publication state is per execution attempt --------------------------

  test "a failed publication can be retried in the same execution with the same identity" do
    in_job do
      first = Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1")).event
      retried = Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"))

      assert_equal first.id, retried.event.id

      again = Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"))
      assert_equal first.id, again.event.id, "repeated failures must stay retryable"
    end
  end

  test "a publication after success is rejected as a duplicate" do
    in_job do
      prepared = Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"))
      Publication.succeeded!(prepared)

      error = assert_raises(EventRail::DuplicatePublicationError) do
        Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"))
      end

      assert_equal prepared.event.id, error.event_id
      assert_equal "tests.pub_order_placed", error.event_type
    end
  end

  test "a retry whose fact differs from the recorded one is rejected" do
    in_job do
      Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1", note: "first"))

      error = assert_raises(EventRail::RetryPayloadMismatchError) do
        Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1", note: "changed"))
      end

      assert_includes error.differing_fields, "payload"
    end

    in_job do
      Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"))

      error = assert_raises(EventRail::RetryPayloadMismatchError) do
        Publication.prepare(
          PublicationFixtures::OrderPlaced.new(order_id: "o-1", occurred_at: Time.utc(2026, 1, 1))
        )
      end

      assert_includes error.differing_fields, "occurred_at"
    end

    in_job do
      Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"))

      error = assert_raises(EventRail::RetryPayloadMismatchError) do
        Publication.prepare(
          PublicationFixtures::OrderPlaced.new(order_id: "o-1", extensions: { "extra" => "1" })
        )
      end

      assert_includes error.differing_fields, "extensions"
    end
  end

  test "no publication state is recorded outside a job execution" do
    prepared = Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"))
    Publication.succeeded!(prepared)

    assert Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1")),
      "a duplicate check outside an execution would reject a legitimate publication"
  end

  test "a nested execution does not observe its parent's publication state" do
    in_job(scope: "outer-job") do
      outer = Publication.prepare(PublicationFixtures::Keyless.new(note: "n"))
      Publication.succeeded!(outer)

      inner = in_job(job_class: "Orders::SubscriberJob", scope: "inner-event") do
        Publication.prepare(PublicationFixtures::Keyless.new(note: "n"))
      end

      refute_equal outer.event.id, inner.event.id
    end
  end

  test "a nested execution restores its parent exactly" do
    in_job(scope: "outer-job") do |outer|
      in_job(job_class: "Other", scope: "inner") { nil }

      assert_same outer, Execution.current,
        "Active Job never restores ExecutionContext[:job], so EventRail must own the stack"
    end
  end

  # --- 3.5 occurrence time ------------------------------------------------------

  test "an explicit domain occurrence time is preserved" do
    stamped = in_job do
      Publication.prepare(
        PublicationFixtures::Keyless.new(note: "n", occurred_at: "2026-07-04T12:00:00+02:00")
      ).event
    end

    assert_equal Time.utc(2026, 7, 4, 10, 0, 0), stamped.occurred_at
  end

  test "the default occurrence time is the execution start, so it survives a retry" do
    first, retried = in_job do
      one = Publication.prepare(PublicationFixtures::Keyless.new(note: "n")).event
      two = Publication.prepare(PublicationFixtures::Keyless.new(note: "n")).event
      [ one, two ]
    end

    assert_equal EXECUTION_START, first.occurred_at
    assert_equal first.occurred_at, retried.occurred_at
  end

  test "a derived event does not inherit its cause's occurrence time" do
    cause_time = Time.utc(2026, 1, 1)
    subscriber_start = Time.utc(2026, 9, 1, 12, 0, 0)

    follow_up = in_job(job_class: "Orders::SubscriberJob", scope: "evt-cause", started_at: subscriber_start) do
      Publication.prepare(PublicationFixtures::Keyless.new(note: "follow-up")).event
    end

    assert_equal subscriber_start, follow_up.occurred_at
    assert_operator follow_up.occurred_at, :>, cause_time
  end

  test "publication outside any execution uses publication time" do
    before = Time.now.utc.floor(6)
    stamped = Publication.prepare(PublicationFixtures::Keyless.new(note: "n")).event

    assert_operator stamped.occurred_at, :>=, before
  end

  # --- lineage ------------------------------------------------------------------

  test "a local event inherits correlation and records the current message as cause" do
    stamped = in_job { Publication.prepare(PublicationFixtures::Keyless.new(note: "n")).event }

    assert_equal "corr-1", stamped.correlation_id
    assert_equal "job-1", stamped.causation_id
  end

  test "a root event with no context roots correlation on its own identity" do
    stamped = Publication.prepare(PublicationFixtures::Keyless.new(note: "n")).event

    assert_equal stamped.id, stamped.correlation_id
    assert_nil stamped.causation_id
  end

  test "a published event merges context and event-local extensions" do
    stamped = in_job do
      EventRail::Current.extensions = { "tenant" => "acme" }.freeze
      Publication.prepare(PublicationFixtures::Keyless.new(note: "n", extensions: { "locale" => "de" })).event
    end

    assert_equal({ "tenant" => "acme", "locale" => "de" }, stamped.extensions)
  end

  test "a published event rejects an extension whose value conflicts with the context" do
    in_job do
      EventRail::Current.extensions = { "tenant" => "acme" }.freeze

      assert_raises(EventRail::InvalidEvent) do
        Publication.prepare(PublicationFixtures::Keyless.new(note: "n", extensions: { "tenant" => "other" }))
      end
    end
  end

  private
    def external_event(causation_id: nil)
      PublicationFixtures::OrderPlaced.send(
        :__reconstruct__,
        data: { "order_id" => "o-ext" },
        metadata: EventRail::Metadata.complete(
          id: "ext-1",
          source: "partner.billing",
          occurred_at: Time.utc(2026, 8, 1),
          correlation_id: "ext-corr",
          causation_id: causation_id,
          extensions: { "region" => "eu" }
        )
      )
    end
end
