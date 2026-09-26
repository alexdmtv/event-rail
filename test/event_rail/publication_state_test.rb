require "test_helper"

# These fixtures are defined after the host application has been prepared, which is the case
# the registry refuses by default. The declaration window is the public door for it.
EventRail::TestHelper.declare do
  module PublicationFixtures
    class OrderPlaced < EventRail::Event
      event_type "tests.pub_order_placed"
      version 1
      default_source "acme.orders"

      attribute :order_id, :string
      attribute :note, :string
      identity_by :order_id
    end

    # Version 2 of the same fact: a new representation, the same occurrence.
    class OrderPlacedV2 < EventRail::Event
      event_type "tests.pub_order_placed"
      version 2
      default_source "acme.orders"

      attribute :order_id, :string
      attribute :note, :string
      identity_by :order_id
    end

    # An event type that moved from call-site identity (version 1) to a declared
    # attribute (version 2).
    class Migrated < EventRail::Event
      event_type "tests.pub_migrated"
      version 1
      default_source "acme.orders"

      attribute :order_id, :string
    end

    class MigratedV2 < EventRail::Event
      event_type "tests.pub_migrated"
      version 2
      default_source "acme.orders"

      attribute :order_id, :string
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
end

class PublicationStateTest < ActiveSupport::TestCase
  Publication = EventRailInternal::Stamping
  Execution = EventRailInternal::Execution
  Identity = EventRailInternal::Identity

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

  test "distinct explicit identities distinguish repeated facts of one type" do
    ids = in_job do
      [ "a", "b" ].map { |identity| Publication.prepare(PublicationFixtures::Keyless.new(note: "n"), identity: identity).event.id }
    end

    assert_equal 2, ids.uniq.length
  end

  test "a declared fact has one ID whichever execution publishes it" do
    placing = in_job(job_class: "Orders::PlaceOrderJob", scope: "job-1") { placed("o-1").id }
    resuming = in_job(job_class: "Orders::ResumeCheckoutJob", scope: "job-2") { placed("o-1").id }
    outside = placed("o-1").id

    assert_equal [ placing ], [ resuming, outside ].uniq
    assert_equal Identity.fact(source: "acme.orders", event_type: "tests.pub_order_placed", identity: [ "o-1" ]), placing
  end

  test "both versions of a fact share its ID" do
    v1 = in_job { placed("o-1").id }
    v2 = in_job(scope: "job-2") { Publication.prepare(PublicationFixtures::OrderPlacedV2.new(order_id: "o-1")).event.id }

    assert_equal v1, v2
  end

  test "moving from an explicit identity to a declared string attribute keeps the fact's ID" do
    before = Publication.prepare(PublicationFixtures::Migrated.new(order_id: "o-1"), identity: "o-1").event.id
    after = Publication.prepare(PublicationFixtures::MigratedV2.new(order_id: "o-1")).event.id

    assert_equal before, after
  end

  test "a declared fact published inside a context block has its fact ID" do
    inside = EventRail.with_context(message_id: "req-1") { placed("o-1").id }

    assert_equal placed("o-1").id, inside
  end

  test "an undeclared event inside a context block in a job keeps the job's identity rules" do
    first = in_job { EventRail.with_context(extensions: { "step" => "a" }) { Publication.prepare(PublicationFixtures::Keyless.new(note: "n")).event.id } }
    retried = in_job { EventRail.with_context(extensions: { "step" => "a" }) { Publication.prepare(PublicationFixtures::Keyless.new(note: "n")).event.id } }
    assert_equal first, retried

    in_job do
      EventRail.with_context(extensions: { "step" => "a" }) do
        Publication.succeeded!(Publication.prepare(PublicationFixtures::Keyless.new(note: "n")))
        assert_raises(EventRail::DuplicatePublicationError) { Publication.prepare(PublicationFixtures::Keyless.new(note: "n")) }
      end
    end
  end

  test "an empty declared identity cannot be constructed" do
    error = assert_raises(EventRail::InvalidEvent) { PublicationFixtures::OrderPlaced.new(order_id: "") }

    assert_match(/order_id .*cannot be nil or empty/, error.message)
  end

  test "an explicit identity cannot override the identity a class declares" do
    error = assert_raises(EventRail::PublicationError) do
      Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"), identity: "other")
    end

    assert_match(/declares order_id/, error.message)
  end

  test "publish's former key: keyword is refused with directions" do
    error = assert_raises(ArgumentError) { EventRail.publish(PublicationFixtures::Keyless.new(note: "n"), key: "a") }

    assert_match(/key: is now identity:/, error.message)
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

  test "an explicit identity must be a string so one value cannot derive two identities" do
    in_job do
      assert_raises(EventRail::PublicationError) do
        Publication.prepare(PublicationFixtures::Keyless.new(note: "n"), identity: 1)
      end
      assert_raises(EventRail::PublicationError) do
        Publication.prepare(PublicationFixtures::Keyless.new(note: "n"), identity: "")
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

  test "an undeclared event outside a job execution gets a random, time-ordered identity" do
    one = Publication.prepare(PublicationFixtures::Keyless.new(note: "n")).event
    sleep 0.002
    two = Publication.prepare(PublicationFixtures::Keyless.new(note: "n")).event

    refute_equal one.id, two.id
    assert_match(/\A\h{8}-\h{4}-7\h{3}-[89ab]\h{3}-\h{12}\z/, one.id, "a version 7 UUID")
    assert_operator one.id, :<, two.id
  end

  test "a derived identity is a version 5 UUID" do
    assert_match(/\A\h{8}-\h{4}-5\h{3}-[89ab]\h{3}-\h{12}\z/, placed("o-1").id)
    assert_match(/\A\h{8}-\h{4}-5\h{3}-[89ab]\h{3}-\h{12}\z/, in_job { Publication.prepare(PublicationFixtures::Keyless.new(note: "n")).event.id })
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

  test "a relay keeps its lineage as it arrived, an absent causation included" do
    without_cause = in_job { Publication.prepare(external_event).event }
    assert_nil without_cause.causation_id
    assert_equal "ext-corr", without_cause.correlation_id

    with_cause = in_job { Publication.prepare(external_event(causation_id: "ext-cause")).event }
    assert_equal "ext-cause", with_cause.causation_id
  end

  test "a publication identity cannot apply to an event that already carries an identity" do
    in_job do
      assert_raises(EventRail::PublicationError) { Publication.prepare(external_event, identity: "k") }
    end
  end

  test "a relay retried with a different fact is rejected" do
    in_job do
      Publication.prepare(external_event)

      assert_raises(EventRail::RetryPayloadMismatchError) { Publication.prepare(external_event(order_id: "o-other")) }
    end
  end

  test "a relay retried with the same fact reuses its record" do
    in_job do
      Publication.prepare(external_event)
      again = Publication.prepare(external_event)

      assert_equal "ext-1", again.event.id
      Publication.succeeded!(again)
      assert_raises(EventRail::DuplicatePublicationError) { Publication.prepare(external_event) }
    end
  end

  test "an event whose ID is not text relays unchanged" do
    binary_id = "\xFF\xFEid".b

    [ -> { Publication.prepare(external_event(id: binary_id)).event }, -> { in_job { Publication.prepare(external_event(id: binary_id)).event } } ].each do |relay|
      assert_equal binary_id, relay.call.id
    end
  end

  test "publishing the stamped result of a failed local publication is its retry" do
    in_job do
      stamped = Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1", note: "first")).event
      changed = PublicationFixtures::OrderPlaced.send(:__reconstruct__, data: { "order_id" => "o-1", "note" => "changed" }, metadata: stamped.metadata)

      assert_raises(EventRail::RetryPayloadMismatchError) { Publication.prepare(changed) }
    end
  end

  test "publishing the stamped result again after success is a duplicate" do
    in_job do
      prepared = Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"))
      Publication.succeeded!(prepared)

      assert_raises(EventRail::DuplicatePublicationError) { Publication.prepare(prepared.event) }
    end
  end

  test "mutating the string passed as source moves no record" do
    in_job do
      source = +"north.shop"
      Publication.succeeded!(Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"), source: source))
      source.replace("south.shop")

      assert_raises(EventRail::DuplicatePublicationError) do
        Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"), source: "north.shop")
      end
    end

    in_job do
      source = +"north.shop"
      Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1", note: "first"), source: source)
      source.replace("south.shop")

      assert_raises(EventRail::RetryPayloadMismatchError) do
        Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1", note: "changed"), source: "north.shop")
      end
    end
  end

  test "relays that share an ID but not a source are two facts" do
    in_job do
      Publication.succeeded!(Publication.prepare(external_event))
      other = Publication.prepare(external_event(source: "partner.shipping"))

      assert_equal [ "ext-1", "partner.shipping" ], [ other.event.id, other.event.source ]
    end
  end

  # --- publishing on behalf of another producer --------------------------------

  test "a publication source replaces the class default and names the fact" do
    ours = placed("o-1")
    theirs = Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"), source: "partner.shop").event

    assert_equal "partner.shop", theirs.source
    assert_equal Identity.fact(source: "partner.shop", event_type: "tests.pub_order_placed", identity: [ "o-1" ]), theirs.id
    refute_equal ours.id, theirs.id
  end

  test "a publication source must be a valid source" do
    assert_raises(EventRail::InvalidMetadata) { Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"), source: "") }
  end

  test "a relayed event cannot be re-attributed to another source" do
    error = assert_raises(EventRail::InvalidMetadata) { Publication.prepare(external_event, source: "acme.billing") }
    assert_match(/re-attribute/, error.message)

    assert_equal "partner.billing", Publication.prepare(external_event, source: "partner.billing").event.source
  end

  test "the publish notification reports the resolved source" do
    sources = []
    capture = ->(event) { sources << event.payload[:source] }

    ActiveSupport::Notifications.subscribed(capture, "publish.event_rail") do
      EventRail.publish(PublicationFixtures::OrderPlaced.new(order_id: "o-1"), source: "partner.shop")
    end

    assert_equal [ "partner.shop" ], sources
  end

  # --- one execution, several sources or versions ------------------------------

  test "one execution publishes the same fact for two sources" do
    in_job do
      first = Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"), source: "north.shop")
      Publication.succeeded!(first)
      second = Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"), source: "south.shop")

      refute_equal first.event.id, second.event.id
    end
  end

  test "a failed publication for one source never lends its ID to another" do
    in_job do
      failed = Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"), source: "north.shop")
      other = Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"), source: "south.shop")

      refute_equal failed.event.id, other.event.id
    end
  end

  test "one execution publishes both versions of a fact under one ID" do
    in_job do
      v1 = Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: "o-1"))
      Publication.succeeded!(v1)
      v2 = Publication.prepare(PublicationFixtures::OrderPlacedV2.new(order_id: "o-1"))

      assert_equal v1.event.id, v2.event.id
    end
  end

  test "a declared follow-up has one ID under any cause and records each cause" do
    first = in_job(scope: "evt-a") { placed("o-1") }
    second = in_job(scope: "evt-b") { placed("o-1") }

    assert_equal first.id, second.id
    assert_equal [ "evt-a", "evt-b" ], [ first.causation_id, second.causation_id ]
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
    def placed(order_id)
      Publication.prepare(PublicationFixtures::OrderPlaced.new(order_id: order_id)).event
    end

    def external_event(causation_id: nil, order_id: "o-ext", source: "partner.billing", id: "ext-1")
      PublicationFixtures::OrderPlaced.send(
        :__reconstruct__,
        data: { "order_id" => order_id },
        metadata: EventRail::Metadata.complete(
          id: id,
          source: source,
          occurred_at: Time.utc(2026, 8, 1),
          correlation_id: "ext-corr",
          causation_id: causation_id,
          extensions: { "region" => "eu" }
        )
      )
    end
end
