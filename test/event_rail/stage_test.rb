require "test_helper"

Registry.reopen do
  module StageFixtures
    class Placed < EventRail::Event
      event_type "tests.stage_placed"
      version 1
      default_source "acme.orders"

      attribute :order_id, :string
      attribute :note, :string
      identity_by :order_id
    end

    # No declared identity: inside a job its ID derives from the execution, outside one it
    # is random.
    class Noted < EventRail::Event
      event_type "tests.stage_noted"
      version 1
      default_source "acme.orders"

      attribute :note, :string
    end

    class Lonely < EventRail::Event
      event_type "tests.stage_lonely"
      version 1
      default_source "acme.orders"

      attribute :order_id, :string
      identity_by :order_id
    end

    class Base < ActiveJob::Base
      include EventRail::JobContext
    end

    # Records the lineage it ran with.
    class First < Base
      subscribes_to Placed

      cattr_accessor :seen, default: []

      def perform(event)
        seen << { correlation_id: EventRail::Current.correlation_id, message_id: EventRail::Current.message_id }
      end
    end

    # Its queue is a block, which must stay unevaluated until the stager serializes the job.
    class Second < Base
      subscribes_to Placed

      cattr_accessor :queue_evaluations, default: 0
      queue_as do
        self.class.queue_evaluations += 1
        :default
      end

      def perform(event)
        event
      end
    end

    class Third < Base
      subscribes_to Placed

      cattr_accessor :enqueue_callbacks, default: 0
      before_enqueue { self.class.enqueue_callbacks += 1 }

      def perform(event)
        event
      end
    end

    class Fragile < EventRail::Event
      event_type "tests.stage_fragile"
      version 1
      default_source "acme.orders"

      attribute :order_id, :string
      attribute :note, :string
      identity_by :order_id
    end

    # A subscriber that can be told to fail while it is being built, before any stager sees it.
    class OnFragile < Base
      subscribes_to Fragile

      cattr_accessor :explode, default: false

      def initialize(...)
        super
        raise ArgumentError, "cannot be built" if self.class.explode
      end

      def perform(event)
        event
      end
    end

    # A namespace whose lookups fail from the inside, as a stager file with a bug of its own
    # would: a NameError that names no missing constant, and one naming some other constant.
    module Broken
      def self.const_missing(name)
        case name
        when :Anonymous then raise NameError, "internal failure"
        when :Elsewhere then raise NameError.new("uninitialized constant Unrelated", :Unrelated)
        else super
        end
      end
    end

    # A namespace reached through an alias of it.
    module Canonical; end
    Aliased = Canonical

    # A stager whose name is not ASCII, which Ruby allows.
    const_set("Étage", Module.new { def self.stage(jobs) = jobs })

    class OnNoted < Base
      subscribes_to Noted

      def perform(event)
        event
      end
    end

    # Runs whatever a test gives it inside a real job execution, the scope staging's
    # duplicate check applies to.
    class Runner < Base
      cattr_accessor :body

      def perform
        body.call
      end
    end

    class Boom < StandardError; end

    # Stages, then fails its first attempt, so the retry stages again in a new execution.
    class Retrying < Base
      cattr_accessor :attempts, default: 0
      retry_on Boom, wait: 0, attempts: 2

      def perform
        self.class.attempts += 1
        EventRail.stage(Noted.new(note: "n"))
        raise Boom if attempts == 1
      end
    end
  end
end

Registry.prepare

class StageTest < ActiveSupport::TestCase
  BASE_PAYLOAD_KEYS = %i[event_type event_version event_id source correlation_id causation_id].freeze

  # Keeps what it is handed, in order, one list per call. `attempts` also keeps the calls
  # its behaviour made fail.
  class Recorder
    attr_reader :calls, :attempts

    def initialize(&behaviour)
      @calls = []
      @attempts = []
      @behaviour = behaviour
    end

    def stage(jobs)
      @attempts << jobs
      @behaviour&.call(jobs)
      @calls << jobs
    end

    def jobs
      @calls.flatten
    end
  end

  setup do
    EventRail::Current.reset
    StageFixtures::First.seen = []
    StageFixtures::Second.queue_evaluations = 0
    StageFixtures::Third.enqueue_callbacks = 0
    StageFixtures::Retrying.attempts = 0
    StageFixtures::OnFragile.explode = false
    RecordingStager.reset!
  end

  teardown { EventRail::Current.reset }

  # --- staging instead of publishing ---------------------------------------------

  test "every subscriber is staged in one call, and nothing is enqueued" do
    stager = Recorder.new

    staged = with_stager(stager) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1")) }

    assert_equal 1, stager.calls.length
    assert_equal [ StageFixtures::First, StageFixtures::Second, StageFixtures::Third ], stager.jobs.map(&:class)
    stager.jobs.each { |job| assert_equal [ staged.event ], job.arguments }
    assert_empty enqueued_jobs, "staging must not enqueue"

    assert_instance_of EventRail::StagedPublication, staged
    assert_equal stager.jobs, staged.staged_jobs
    assert_equal stager.jobs.map(&:class), staged.staged_subscribers
    assert_equal 3, staged.subscriber_count
    assert_equal staged.event.id, staged.id
    assert_predicate staged, :frozen?
    assert_predicate staged.staged_jobs, :frozen?
  end

  test "an event with no subscribers is still handed to the stager, as an empty list" do
    stager = Recorder.new

    staged = with_stager(stager) { EventRail.stage(StageFixtures::Lonely.new(order_id: "o-1")) }

    assert_equal [ [] ], stager.calls
    assert_predicate staged.event, :stamped?
    assert_empty staged.staged_jobs
  end

  test "staging stamps exactly as publication does" do
    staged = with_stager(Recorder.new) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1")) }
    published = EventRail.publish(StageFixtures::Placed.new(order_id: "o-1"))

    assert_equal published.event.id, staged.event.id
    assert_equal published.event.source, staged.event.source
  end

  test "explicit identity, source, occurrence time and context stamp as they do for publication" do
    occurred_at = Time.utc(2026, 9, 2, 8, 30, 0)
    attributes = { note: "n" }
    options = { identity: "import-row-7", source: "acme.imports" }
    stamp = lambda do |&verb|
      EventRail.with_context(correlation_id: "corr-1", message_id: "req-1", extensions: { "tenant" => "t-1" }) do
        verb.call(StageFixtures::Noted.new(**attributes, occurred_at: occurred_at))
      end
    end

    staged = with_stager(Recorder.new) { stamp.call { |event| EventRail.stage(event, **options) } }.event
    published = stamp.call { |event| EventRail.publish(event, **options) }.event

    %i[id source occurred_at correlation_id causation_id extensions].each do |field|
      assert_equal published.public_send(field), staged.public_send(field), field
    end
    assert_equal "acme.imports", staged.source
  end

  test "an event that is already stamped is relayed with its identity and lineage" do
    original = EventRail.with_context(correlation_id: "corr-origin", message_id: "req-origin") do
      EventRail.publish(StageFixtures::Placed.new(order_id: "o-1")).event
    end

    staged = with_stager(Recorder.new) do
      EventRail.with_context(correlation_id: "corr-local", message_id: "req-local") { EventRail.stage(original) }
    end

    assert_equal original.id, staged.event.id
    assert_equal original.source, staged.event.source
    assert_equal "corr-origin", staged.event.correlation_id
    assert_equal "req-origin", staged.event.causation_id
  end

  test "EventRail runs no enqueue callback while staging" do
    with_stager(Recorder.new) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1")) }

    assert_equal 0, StageFixtures::Third.enqueue_callbacks
  end

  test "staging before preparation is not ready before any stager is looked up" do
    snapshot = Registry.instance_variable_get(:@snapshot)
    Registry.instance_variable_set(:@snapshot, nil)

    # A name that resolves to nothing would be a configuration error, so seeing not-ready
    # instead shows readiness is checked first.
    with_stager("NoSuchStager") do
      assert_raises(EventRail::NotReadyError) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1")) }
    end
  ensure
    Registry.instance_variable_set(:@snapshot, snapshot)
  end

  test "staging before preparation is not ready, and the stager is never called" do
    stager = Recorder.new
    snapshot = Registry.instance_variable_get(:@snapshot)
    Registry.instance_variable_set(:@snapshot, nil)

    with_stager(stager) do
      assert_raises(EventRail::NotReadyError) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1")) }
    end

    assert_empty stager.calls
  ensure
    Registry.instance_variable_set(:@snapshot, snapshot)
  end

  test "the retired key: keyword fails exactly as it does for publish" do
    staging = assert_raises(ArgumentError) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1"), key: "k") }
    publishing = assert_raises(ArgumentError) { EventRail.publish(StageFixtures::Placed.new(order_id: "o-1"), key: "k") }

    assert_match(/identity:/, staging.message)
    assert_equal publishing.message.sub("publish's", "stage's"), staging.message
    assert_raises(ArgumentError) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1"), bogus: 1) }
  end

  # --- the stager is configured once ---------------------------------------------

  test "a stager configured by name is resolved and receives the jobs" do
    with_stager("RecordingStager") { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1")) }

    assert_equal 3, RecordingStager.staged.length
  end

  test "staging with no stager is a configuration error naming the setting, and enqueues nothing" do
    error = with_stager(nil) do
      assert_raises(EventRail::ConfigurationError) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1")) }
    end

    assert_match(/config\.event_rail\.stager/, error.message)
    assert_empty enqueued_jobs
  end

  test "staging without a Rails application is a configuration error" do
    Rails.stub(:application, nil) do
      error = assert_raises(EventRail::ConfigurationError) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1")) }
      assert_match(/config\.event_rail\.stager/, error.message)
    end
  end

  test "a stager may be named by a Symbol too" do
    with_stager(:RecordingStager) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1")) }

    assert_equal 3, RecordingStager.staged.length
  end

  test "the stager receives a list it may change without changing the result" do
    trimming = Recorder.new { |jobs| jobs.pop }

    staged = with_stager(trimming) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1")) }

    assert_equal 3, staged.staged_jobs.length
  end

  test "a failure before the stager is called leaves nothing recorded in the execution" do
    StageFixtures::Runner.body = lambda do
      StageFixtures::OnFragile.explode = true
      assert_raises(ArgumentError) { EventRail.stage(StageFixtures::Fragile.new(order_id: "o-1", note: "first")) }
      StageFixtures::OnFragile.explode = false

      # A recorded, unfinished first attempt would make this a retry with a different payload.
      EventRail.stage(StageFixtures::Fragile.new(order_id: "o-1", note: "second"))
    end

    staged = with_stager(Recorder.new) { StageFixtures::Runner.perform_now }

    assert_equal "second", staged.event.note
  end

  test "a notification handler failing as the block starts leaves nothing recorded" do
    stager = Recorder.new
    starting = Object.new
    def starting.start(*) = raise(StageFixtures::Boom, "handler")
    def starting.finish(*) = nil

    in_job(stager) do
      subscription = ActiveSupport::Notifications.subscribe("stage.event_rail", starting)
      begin
        assert_raises(StageFixtures::Boom) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1", note: "first")) }
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription)
      end
      EventRail.stage(StageFixtures::Placed.new(order_id: "o-1", note: "second"))
    end

    assert_equal [ "second" ], stager.calls.map { |jobs| jobs.first.arguments.first.note }
  end

  test "a configuration error leaves nothing recorded in the execution" do
    StageFixtures::Runner.body = lambda do
      with_stager(nil) do
        assert_raises(EventRail::ConfigurationError) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1", note: "first")) }
      end
      # A recorded, unfinished first attempt would make this a retry with a different
      # payload, and refuse it.
      with_stager(Recorder.new) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1", note: "second")) }
    end

    staged = StageFixtures::Runner.perform_now

    assert_equal "second", staged.event.note
  end

  test "preparation fails for a name that resolves to nothing" do
    with_stager("NoSuchStager") do
      error = assert_raises(EventRail::ConfigurationError) { Registry.prepare }
      assert_match(/config\.event_rail\.stager/, error.message)
      assert_match(/NoSuchStager/, error.message)
    end
  ensure
    Registry.prepare
  end

  test "preparation fails for a name that is not a constant path" do
    [ "", "::", "String::", "lowercase", "Two Words", "_Private", "étage" ].each do |bad|
      with_stager(bad) do
        error = assert_raises(EventRail::ConfigurationError, "#{bad.inspect} must be rejected") { Registry.prepare }
        assert_match(/not a constant/, error.message)
      end
    end
  ensure
    Registry.prepare
  end

  test "a stager named in Unicode resolves, as Ruby allows" do
    with_stager("StageFixtures::Étage") { assert Registry.prepare }
  ensure
    Registry.prepare
  end

  test "a missing constant reached through an aliased namespace is a configuration error" do
    with_stager("StageFixtures::Aliased::NoSuchStager") do
      error = assert_raises(EventRail::ConfigurationError) { Registry.prepare }
      assert_match(/StageFixtures::Aliased::NoSuchStager/, error.message)
    end
  ensure
    Registry.prepare
  end

  test "preparation fails for a nested name whose last constant is missing" do
    with_stager("StageFixtures::NoSuchStager") do
      assert_raises(EventRail::ConfigurationError) { Registry.prepare }
    end
  ensure
    Registry.prepare
  end

  test "a NameError from inside the stager's own code is not mistaken for a missing stager" do
    [ "StageFixtures::Broken::Anonymous", "StageFixtures::Broken::Elsewhere" ].each do |name|
      with_stager(name) do
        error = assert_raises(NameError, name) { Registry.prepare }
        refute_kind_of EventRail::ConfigurationError, error
      end
    end
  ensure
    Registry.prepare
  end

  test "preparation fails for a stager that does not respond to stage" do
    [ "Object", Object.new ].each do |bad|
      with_stager(bad) do
        error = assert_raises(EventRail::ConfigurationError, "#{bad.inspect} must be rejected") { Registry.prepare }
        assert_match(/does not respond to stage/, error.message)
      end
    end
  ensure
    Registry.prepare
  end

  test "an application with no stager prepares normally" do
    with_stager(nil) { assert Registry.prepare }
  ensure
    Registry.prepare
  end

  # --- notifications -------------------------------------------------------------

  test "staging emits stage.event_rail without domain data, and no enqueue notification" do
    payloads = Hash.new { |hash, key| hash[key] = [] }
    recorder = ->(name, _start, _finish, _id, payload) { payloads[name] << payload }

    ActiveSupport::Notifications.subscribed(recorder, /\A(stage|enqueue_subscriber)\.event_rail\z/) do
      with_stager(Recorder.new) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1", note: "do not log me")) }
    end

    assert_equal [ "stage.event_rail" ], payloads.keys
    payload = payloads["stage.event_rail"].sole
    assert_equal (BASE_PAYLOAD_KEYS + [ :subscriber_count ]).sort, payload.keys.sort
    assert_equal 3, payload[:subscriber_count]
    refute_includes payload.values.map(&:to_s).join(" "), "do not log me"
  end

  # --- the duplicate check staging shares with publication -------------------------

  test "a raising stager's exception reaches the caller, and staging again is a retry" do
    failing = true
    stager = Recorder.new { raise StageFixtures::Boom, "store down" if failing }

    error = nil
    in_job(stager) do
      error = assert_raises(StageFixtures::Boom) { EventRail.stage(StageFixtures::Noted.new(note: "n")) }
      failing = false
      EventRail.stage(StageFixtures::Noted.new(note: "n"))
    end

    assert_equal "store down", error.message
    failed, retried = stager.attempts.map { |jobs| jobs.sole.arguments.first.id }
    assert_equal failed, retried
  end

  test "a raising notification handler's exception reaches the caller, and staging again is a retry" do
    stager = Recorder.new
    raising = ->(*) { raise StageFixtures::Boom, "handler" }

    in_job(stager) do
      ActiveSupport::Notifications.subscribed(raising, "stage.event_rail") do
        assert_raises(StageFixtures::Boom) { EventRail.stage(StageFixtures::Noted.new(note: "n")) }
      end
      EventRail.stage(StageFixtures::Noted.new(note: "n"))
    end

    first, second = stager.calls.map { |jobs| jobs.sole.arguments.first.id }
    assert_equal first, second
  end

  test "a retry with a different payload is refused" do
    failing = true
    stager = Recorder.new { raise StageFixtures::Boom if failing }

    in_job(stager) do
      assert_raises(StageFixtures::Boom) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1", note: "a")) }
      failing = false
      assert_raises(EventRail::RetryPayloadMismatchError) do
        EventRail.stage(StageFixtures::Placed.new(order_id: "o-1", note: "b"))
      end
    end
  end

  test "staging a fact twice, or staging then publishing it, in one job attempt is a duplicate" do
    in_job(Recorder.new) do
      EventRail.stage(StageFixtures::Placed.new(order_id: "o-1"))

      assert_raises(EventRail::DuplicatePublicationError) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1")) }
      assert_raises(EventRail::DuplicatePublicationError) { EventRail.publish(StageFixtures::Placed.new(order_id: "o-1")) }
    end
  end

  test "a retried job stages under the same event ID" do
    stager = Recorder.new

    with_stager(stager) do
      StageFixtures::Retrying.perform_now
      perform_enqueued_jobs
    end

    assert_equal 2, StageFixtures::Retrying.attempts
    ids = stager.calls.map { |jobs| jobs.sole.arguments.first.id }
    assert_equal 2, ids.length
    assert_equal 1, ids.uniq.length, "an undeclared event derives its ID from the job, which a retry keeps"
  end

  test "outside a job, staging the same event twice raises nothing" do
    stager = Recorder.new

    with_stager(stager) do
      2.times { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1")) }
    end

    assert_equal 2, stager.calls.length
  end

  # --- a staged job's context does not depend on when it is serialized --------------

  test "a job serialized after the staging context ended carries that context's origin time" do
    origin = Time.utc(2026, 9, 1, 12, 0, 0)
    stager = Recorder.new

    with_stager(stager) do
      EventRail.with_context(message_id: "req-1", originated_at: origin) do
        EventRail.stage(StageFixtures::Placed.new(order_id: "o-1"))
      end
    end

    entry = stager.jobs.first.serialize.fetch(EventRail::JobContext::ENTRY_KEY)
    assert_equal EventRailInternal::Timestamp.written(origin), entry.fetch("originated_at")
  end

  test "staging leaves a subscriber's queue block for the stager to evaluate" do
    stager = Recorder.new

    with_stager(stager) { EventRail.stage(StageFixtures::Placed.new(order_id: "o-1")) }

    assert_equal 0, StageFixtures::Second.queue_evaluations
    stager.jobs.find { |job| job.is_a?(StageFixtures::Second) }.serialize
    assert_equal 1, StageFixtures::Second.queue_evaluations
  end

  test "a staged job runs in its event's flow, performed outside any context" do
    stager = Recorder.new

    staged = with_stager(stager) do
      EventRail.with_context(correlation_id: "corr-1", message_id: "req-1") do
        EventRail.stage(StageFixtures::Placed.new(order_id: "o-1"))
      end
    end
    data = stager.jobs.find { |job| job.is_a?(StageFixtures::First) }.serialize

    EventRail::Current.reset
    ActiveJob::Base.execute(JSON.parse(JSON.generate(data)))

    assert_equal [ { correlation_id: "corr-1", message_id: staged.event.id } ], StageFixtures::First.seen
  end

  private
    def with_stager(value)
      config = Rails.application.config.event_rail
      original = config.stager
      config.stager = value
      yield
    ensure
      config.stager = original
    end

    # A real job attempt: JobContext installs the execution the duplicate check is scoped to.
    def in_job(stager, &body)
      StageFixtures::Runner.body = body
      with_stager(stager) { StageFixtures::Runner.perform_now }
    end
end
