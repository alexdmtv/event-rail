require "test_helper"
require "json"

module JobContextFixtures
  class Base < ActiveJob::Base
    include EventRail::JobContext
  end

  # Records the lineage that was installed while it ran, so a test can assert on the
  # context a worker actually sees rather than on the serialized entry alone.
  class Observing < Base
    class << self
      attr_accessor :observed
    end
    self.observed = []

    def perform(*)
      self.class.observed << {
        message_id: EventRail::Current.message_id,
        correlation_id: EventRail::Current.correlation_id,
        causation_id: EventRail::Current.causation_id,
        originated_at: EventRail::Current.originated_at,
        extensions: EventRail::Current.extensions,
        execution: EventRailInternal::Execution.current
      }
    end
  end

  class Enqueuing < Base
    def perform
      Observing.perform_later
    end
  end

  class Plain < ActiveJob::Base
    def perform; end
  end
end

class JobContextTest < ActiveSupport::TestCase
  ENTRY_KEY = EventRail::JobContext::ENTRY_KEY

  setup do
    EventRail::Current.reset
    JobContextFixtures::Observing.observed = []
  end

  teardown { EventRail::Current.reset }

  # --- 4.1 one reserved, versioned, primitive-valued entry ----------------------

  test "the entry carries only JSON primitives and survives a JSON cycle" do
    entry = EventRail.with_context(message_id: "req-1", extensions: { "tenant" => "acme" }) do
      JobContextFixtures::Observing.new.serialize.fetch(ENTRY_KEY)
    end

    assert_equal entry, JSON.parse(JSON.generate(entry))
    assert_equal EventRail::JobContext::ENTRY_VERSION, entry.fetch("v")
  end

  test "the entry records the boundary lineage a child job inherits" do
    job = EventRail.with_context(message_id: "req-1", extensions: { "tenant" => "acme" }) do
      JobContextFixtures::Observing.new
    end

    entry = EventRail.with_context(message_id: "req-1", extensions: { "tenant" => "acme" }) do
      job.serialize.fetch(ENTRY_KEY)
    end

    assert_equal job.job_id, entry.fetch("message_id")
    assert_equal "req-1", entry.fetch("correlation_id")
    assert_equal "req-1", entry.fetch("causation_id")
    assert_equal({ "tenant" => "acme" }, entry.fetch("extensions"))
  end

  test "a queue round trip preserves lineage into execution" do
    ActiveJob::Base.execute(serialize_in(message_id: "req-1", extensions: { "tenant" => "acme" }))
    observed = JobContextFixtures::Observing.observed.sole

    assert_equal "req-1", observed.fetch(:correlation_id)
    assert_equal "req-1", observed.fetch(:causation_id)
    assert_equal({ "tenant" => "acme" }, observed.fetch(:extensions))
    assert_equal "UTC", observed.fetch(:originated_at).zone
  end

  test "a job's own stable ID becomes its logical message and identity scope" do
    data = serialize_in(message_id: "req-1")
    ActiveJob::Base.execute(data)
    observed = JobContextFixtures::Observing.observed.sole

    assert_equal data.fetch("job_id"), observed.fetch(:message_id)
    assert_equal data.fetch("job_id"), observed.fetch(:execution).scope
    assert_equal "JobContextFixtures::Observing", observed.fetch(:execution).job_class
    assert_predicate observed.fetch(:execution), :derives_identity?
  end

  test "the entry is established once and re-emitted unchanged by a later serialization" do
    job = EventRail.with_context(message_id: "req-1") { JobContextFixtures::Observing.new }
    first = job.serialize.fetch(ENTRY_KEY)

    # A retry scheduled from an exception handler serializes after the perform
    # callbacks have already restored the previous context, so an ambient read here
    # would manufacture a fresh root.
    second = EventRail.with_context(message_id: "unrelated-request") { job.serialize.fetch(ENTRY_KEY) }

    assert_equal first, second
  end

  test "a retry preserves lineage and the execution start it already recorded" do
    # `retry_job` re-enqueues the instance that executed, so the retry's entry is the
    # one that attempt mutated -- which is why the start time it recorded survives.
    running = ActiveJob::Base.deserialize(serialize_in(message_id: "req-1"))
    running.perform_now
    first = JobContextFixtures::Observing.observed.sole

    JobContextFixtures::Observing.observed = []
    ActiveJob::Base.execute(running.serialize)
    second = JobContextFixtures::Observing.observed.sole

    assert_equal first.fetch(:message_id), second.fetch(:message_id)
    assert_equal first.fetch(:correlation_id), second.fetch(:correlation_id)
    assert_equal first.fetch(:causation_id), second.fetch(:causation_id)
    assert_equal first.fetch(:originated_at), second.fetch(:originated_at)
    assert_equal first.fetch(:execution).started_at, second.fetch(:execution).started_at
  end

  test "a job queued before context integration establishes a generated root" do
    data = JobContextFixtures::Observing.new.serialize
    data.delete(ENTRY_KEY)

    ActiveJob::Base.execute(data)
    observed = JobContextFixtures::Observing.observed.sole

    assert_equal data.fetch("job_id"), observed.fetch(:message_id)
    assert_equal data.fetch("job_id"), observed.fetch(:correlation_id)
    assert_nil observed.fetch(:causation_id)
    refute_nil observed.fetch(:originated_at)
  end

  test "an entry version this release cannot read is refused before perform runs" do
    data = JobContextFixtures::Observing.new.serialize
    data[ENTRY_KEY] = data.fetch(ENTRY_KEY).merge("v" => 99)

    error = assert_raises(EventRail::UnsupportedFormatError) { ActiveJob::Base.execute(data) }

    assert_equal 99, error.format_version
    assert_empty JobContextFixtures::Observing.observed
  end

  test "context does not leak out of execution" do
    ActiveJob::Base.execute(serialize_in(message_id: "req-1"))

    assert_nil EventRail::Current.message_id
    assert_nil EventRailInternal::Execution.current
  end

  test "a job that does not opt in is untouched" do
    data = JobContextFixtures::Plain.new.serialize

    refute_includes data.keys, ENTRY_KEY
  end

  # --- 4.2 child-job lineage ----------------------------------------------------

  test "a child job enqueued from a job preserves correlation and records its parent as cause" do
    parent_data = serialize_in(
      message_id: "req-1", extensions: { "tenant" => "acme" }, job_class: JobContextFixtures::Enqueuing
    )
    ActiveJob::Base.execute(parent_data)

    entry = enqueued_jobs.sole.fetch(ENTRY_KEY)

    assert_equal "req-1", entry.fetch("correlation_id")
    assert_equal parent_data.fetch("job_id"), entry.fetch("causation_id")
    assert_equal({ "tenant" => "acme" }, entry.fetch("extensions"))
    refute_equal parent_data.fetch("job_id"), entry.fetch("message_id")
  end

  private
    # The entry is established at the first serialization, so the job has to be built
    # and written inside the context whose lineage it is meant to carry.
    def serialize_in(job_class: JobContextFixtures::Observing, **context)
      EventRail.with_context(**context) { job_class.new.serialize }
    end
end
