require "test_helper"

# Adapter conformance.
#
# The test and async adapters run on every combination in the advertised matrix. Sidekiq,
# Solid Queue, and the OpenTelemetry Active Job instrumentation run only where their gems
# are bundled -- `BUNDLE_GEMFILE=gemfiles/adapters.gemfile` -- on one current stable Ruby
# and Rails combination, and each records why it is absent rather than passing silently.
#
# Excluded on purpose: a Postgres-only backend. Serviceless conformance means the suite
# runs with no external service, and a backend that requires a Postgres server cannot be
# covered that way. That is a deliberate gap in this suite, not an untested claim -- a
# Postgres-backed adapter is an ordinary Active Job adapter and uses the same individual
# `perform_later` path everything else here exercises.
module Conformance
  def self.available?(gem_name, require_path = gem_name)
    require require_path
    true
  rescue LoadError
    false
  end

  SIDEKIQ = available?("sidekiq")
  SOLID_QUEUE = available?("solid_queue")
  OTEL = available?("opentelemetry-instrumentation-active_job", "opentelemetry/instrumentation/active_job")
end

Registry.reopen do
  module ConformanceFixtures
    class Placed < EventRail::Event
      event_type "tests.conformance_placed"
      version 1
      default_source "acme.orders"

      attribute :order_id, :string
      attribute :total, :decimal
      attribute :placed_on, :date
      attribute :placed_at, :datetime
      attribute :properties
      identity_by :order_id
    end

    class Base < ActiveJob::Base
      include EventRail::JobContext
    end

    class OnPlaced < Base
      subscribes_to Placed

      # A queue is not a test harness: the subscriber records what it saw somewhere both
      # the worker thread and the test can reach.
      RECEIVED = Queue.new

      def perform(event)
        RECEIVED << event
      end
    end
  end
end

Registry.prepare

module ConformanceAssertions
  INPUT = {
    order_id: "o-1",
    total: "12.50",
    placed_on: "2026-09-01",
    placed_at: "2026-09-01T10:30:00.123456+02:00",
    properties: { "channel" => { "name" => "web", "weights" => [ 1, 2.5, nil ] } }
  }.freeze

  def publish_one
    EventRail.publish(
      ConformanceFixtures::Placed.new(**INPUT, extensions: { "tenant" => "acme" })
    ).event
  rescue EventRail::EnqueueError => error
    # An adapter that refuses the enqueue is the interesting failure in a conformance run,
    # and the reason lives on the cause rather than in the wrapper's own message.
    flunk "#{error.failed_subscriber} was refused by the adapter: " \
      "#{error.cause.class}: #{error.cause&.message}\n#{error.cause&.backtrace&.first(5)&.join("\n")}"
  end

  def drain_received(timeout: 5)
    Timeout.timeout(timeout) { ConformanceFixtures::OnPlaced::RECEIVED.pop }
  end

  # Comments are stripped: the library talks about `perform_all_later` in order to explain
  # why it does not call it, and a prose mention is not a dependency.
  FORBIDDEN_APIS = %w[perform_all_later Sidekiq SolidQueue Shoryuken Resque OpenTelemetry].freeze

  def assert_no_native_adapter_dependency
    offenders = Dir.glob(File.expand_path("../../lib/**/*.rb", __dir__)).flat_map do |path|
      code = File.readlines(path).grep_v(/^\s*#/).join
      FORBIDDEN_APIS.filter_map { |name| "#{path.split("/lib/").last}: #{name}" if code.include?(name) }
    end

    assert_empty offenders, "the library must not call a bulk-enqueue or native adapter API"
  end
end

class AsyncAdapterConformanceTest < ActiveSupport::TestCase
  include ConformanceAssertions

  def queue_adapter_for_test
    ActiveJob::QueueAdapters::AsyncAdapter.new(min_threads: 1, max_threads: 2)
  end

  setup do
    EventRail::Current.reset
    ConformanceFixtures::OnPlaced::RECEIVED.clear
  end

  teardown { EventRail::Current.reset }

  test "the async adapter delivers a typed event through a real worker thread" do
    event = publish_one
    received = drain_received

    assert_equal event, received
    assert_equal BigDecimal("12.5"), received.total
    assert_equal Date.new(2026, 9, 1), received.placed_on
    assert_equal({ "tenant" => "acme" }, received.extensions)
  end

  test "no bulk fanout and no native adapter API is introduced" do
    assert_no_native_adapter_dependency
  end
end

class TestAdapterConformanceTest < ActiveSupport::TestCase
  include ConformanceAssertions

  setup do
    EventRail::Current.reset
    ConformanceFixtures::OnPlaced::RECEIVED.clear
  end

  teardown { EventRail::Current.reset }

  test "the test adapter needs no native object serialization" do
    publish_one
    arguments = enqueued_jobs.sole.fetch("arguments")

    assert_equal arguments, JSON.parse(JSON.generate(arguments))
    assert_kind_of Hash, arguments.sole
    assert_equal "EventRail::Internal::EventSerializer", arguments.sole.fetch("_aj_serialized")
  end

  test "the delivered event is reconstructed as the registered typed class" do
    event = publish_one
    perform_enqueued_jobs

    assert_equal event, drain_received
  end
end

if Conformance::SIDEKIQ
  class SidekiqConformanceTest < ActiveSupport::TestCase
    include ConformanceAssertions

    # Sidekiq refuses complex arguments by default, so this is the assertion that matters:
    # the serialized form is JSON-native all the way down. No Redis server is involved --
    # `verify_json` is the same check Sidekiq applies at client push.
    class Verifier
      include Sidekiq::JobUtil
    end

    setup { EventRail::Current.reset }
    teardown { EventRail::Current.reset }

    # The test adapter keeps symbol-keyed conveniences of its own alongside the payload;
    # what real Sidekiq receives is the string-keyed job data.
    def job_payload
      publish_one
      enqueued_jobs.sole.except(:job, :args, :queue, :priority)
    end

    test "Sidekiq accepts the serialized argument form" do
      payload = job_payload
      item = { "class" => payload.fetch("job_class"), "args" => [ payload ] }

      assert_nil Verifier.new.verify_json(item)
    end

    test "Sidekiq's own strict argument check passes on the whole job payload" do
      payload = job_payload

      assert_equal payload, JSON.parse(JSON.generate(payload))
      assert_equal payload, Sidekiq.load_json(Sidekiq.dump_json(payload))
    end
  end
end

if Conformance::SOLID_QUEUE
  class SolidQueueConformanceTest < ActiveSupport::TestCase
    include ConformanceAssertions

    # Solid Queue ships its schema as an install-generator template rather than as a
    # loadable file at the gem root, so the path is looked up rather than guessed.
    SCHEMA = Dir.glob(
      "#{Gem.loaded_specs["solid_queue"].gem_dir}/lib/generators/**/templates/db/queue_schema.rb"
    ).first

    def self.prepared?
      return @prepared if defined?(@prepared)

      @prepared = begin
        require "active_record"
        raise LoadError, "no queue_schema.rb template in the solid_queue gem" if SCHEMA.nil?

        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
        ActiveRecord::Schema.verbose = false
        load SCHEMA
        load_solid_queue_models
        install_solid_queue_job_extensions
        true
      rescue StandardError, LoadError => error
        @preparation_error = "#{error.class}: #{error.message}"
        false
      end
    end

    # Solid Queue's models are engine code Zeitwerk would have set up during application
    # boot. The fixture application deliberately has no database, so the gem is loaded
    # afterwards and its models get their own loader here -- plain requires cannot do it,
    # because the models depend on one another in an order only a loader resolves.
    def self.load_solid_queue_models
      loader = Zeitwerk::Loader.new
      loader.push_dir("#{Gem.loaded_specs["solid_queue"].gem_dir}/app/models")
      loader.setup

      # Autoload rather than eager load: Solid Queue's recurring-task models resolve a
      # sibling constant in a way eager loading outside a Rails engine gets wrong, and the
      # only model this conformance run touches is the job table.
      SolidQueue::Job
    end

    # Solid Queue's engine initializer normally mixes two concerns into `ActiveJob::Base`,
    # and its adapter then reads `concurrency_key` and `batch_id` off every job. That
    # initializer cannot run here, because the fixture application has already booted, so
    # the same inclusions happen explicitly. This is fixture plumbing, not something an
    # application ever does: a real application has Solid Queue in its bundle before boot.
    def self.install_solid_queue_job_extensions
      require "active_job/concurrency_controls"
      require "active_job/batch_id"

      [ ActiveJob::ConcurrencyControls, ActiveJob::BatchId ].each do |extension|
        ActiveJob::Base.include(extension) unless ActiveJob::Base.include?(extension)
      end
    end

    def queue_adapter_for_test
      ActiveJob::QueueAdapters::SolidQueueAdapter.new
    end

    setup do
      unless self.class.prepared?
        skip "Solid Queue schema could not be loaded into in-memory SQLite: " \
          "#{self.class.instance_variable_get(:@preparation_error)}"
      end
      EventRail::Current.reset
      SolidQueue::Job.delete_all
    end

    teardown { EventRail::Current.reset }

    test "Solid Queue accepts an individually enqueued event with no native serialization" do
      event = publish_one
      row = SolidQueue::Job.sole

      assert_equal "ConformanceFixtures::OnPlaced", row.class_name
      assert_equal event.id, row.arguments.fetch("arguments").sole.fetch("metadata").fetch("id")
      assert_equal row.arguments, JSON.parse(JSON.generate(row.arguments))
    end

    # Solid Queue is the adapter that brings Active Record with it, so it is the natural
    # place to see the open-transaction check fire against a real transaction.
    test "the open-transaction check fires on a backend that loads Active Record" do
      assert_raises(EventRail::TransactionalPublicationError) do
        ActiveRecord::Base.transaction { publish_one }
      end

      assert_equal 0, SolidQueue::Job.count
    end
  end
end

if Conformance::OTEL
  class OpenTelemetryConformanceTest < ActiveSupport::TestCase
    include ConformanceAssertions

    # Configured once for the process: `OpenTelemetry::SDK.configure` installs a global
    # tracer provider, and calling it again would leave a second exporter attached to
    # nothing.
    def self.exporter
      @exporter ||= begin
        require "opentelemetry-sdk"
        exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
        OpenTelemetry::SDK.configure do |config|
          config.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
          config.use("OpenTelemetry::Instrumentation::ActiveJob")
        end
        exporter
      end
    end

    setup do
      EventRail::Current.reset
      @exporter = self.class.exporter
      @exporter.reset
    end

    teardown { EventRail::Current.reset }

    test "standard instrumentation propagates trace context while event metadata is unchanged" do
      event = publish_one
      instrumented = enqueued_jobs.sole.fetch("arguments").sole

      clear_enqueued_jobs
      EventRail::Current.reset
      plain = EventRail.const_get(:Internal)::EventSerializer.serialize(event)

      assert_equal plain, instrumented,
        "the trace carrier lives beside the event, never inside its durable metadata"
      refute_empty @exporter.finished_spans, "the ambient span must still be recorded"

      metadata = instrumented.fetch("metadata")
      refute_includes metadata.keys, "traceparent"
      refute_includes metadata.keys, "tracestate"
    end

    test "delivery still works with instrumentation installed" do
      event = publish_one
      perform_enqueued_jobs

      assert_equal event, drain_received
    end
  end
end
