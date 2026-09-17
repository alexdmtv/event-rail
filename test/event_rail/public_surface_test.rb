require "test_helper"

Registry.reopen do
  module SurfaceFixtures
    class Placed < EventRail::Event
      event_type "tests.surface_placed"
      version 1
      default_source "acme.orders"

      attribute :order_id, :string
      attribute :secret, :string
      identity_by :order_id
    end

    class Base < ActiveJob::Base
      include EventRail::JobContext
    end

    class OnPlaced < Base
      subscribes_to Placed

      def perform(event)
        event
      end
    end
  end
end

Registry.prepare

class PublicSurfaceTest < ActiveSupport::TestCase
  NOTIFICATION_NAMES = %w[
    publish.event_rail
    enqueue_subscriber.event_rail
    deserialize.event_rail
    perform_subscriber.event_rail
  ].freeze

  BASE_PAYLOAD_KEYS = %i[event_type event_version event_id source correlation_id causation_id].freeze

  setup { EventRail::Current.reset }
  teardown { EventRail::Current.reset }

  # --- 8.1 the four documented notifications ------------------------------------

  test "every documented notification carries the contract, identity, and lineage keys" do
    payloads = capture(NOTIFICATION_NAMES) do
      EventRail.publish(SurfaceFixtures::Placed.new(order_id: "o-1", secret: "do not log me"))
      perform_enqueued_jobs
    end

    assert_equal NOTIFICATION_NAMES.sort, payloads.keys.sort, "every documented notification must fire"

    payloads.each do |name, captured|
      captured.each do |payload|
        BASE_PAYLOAD_KEYS.each do |key|
          assert_includes payload.keys, key, "#{name} is missing #{key}"
        end
      end
    end
  end

  test "no notification payload contains domain data or extensions" do
    payloads = capture(NOTIFICATION_NAMES) do
      EventRail.publish(
        SurfaceFixtures::Placed.new(order_id: "o-1", secret: "do not log me"),
        key: nil
      )
      perform_enqueued_jobs
    end

    payloads.each do |name, captured|
      captured.each do |payload|
        refute_includes payload.keys, :extensions, "#{name} must not expose extensions"
        refute_includes payload.keys, :data, "#{name} must not expose domain data"
        refute_includes payload.inspect, "do not log me", "#{name} leaked a payload value"
      end
    end
  end

  test "each notification carries its own additional keys" do
    payloads = capture(NOTIFICATION_NAMES) do
      EventRail.publish(SurfaceFixtures::Placed.new(order_id: "o-1"))
      perform_enqueued_jobs
    end

    publish = payloads.fetch("publish.event_rail").sole
    assert_equal 1, publish.fetch(:subscriber_count)
    assert_equal 1, publish.fetch(:accepted)
    assert_equal 0, publish.fetch(:skipped)

    assert_equal "SurfaceFixtures::OnPlaced", payloads.fetch("enqueue_subscriber.event_rail").sole.fetch(:job_class)
    assert_equal "accepted", payloads.fetch("enqueue_subscriber.event_rail").sole.fetch(:outcome)
    assert_equal 1, payloads.fetch("deserialize.event_rail").sole.fetch(:format_version)
    assert_equal "SurfaceFixtures::OnPlaced", payloads.fetch("perform_subscriber.event_rail").sole.fetch(:job_class)
  end

  # --- 8.2 consumers need no EventRail test API ---------------------------------

  test "an application tests EventRail with Active Job's own helpers alone" do
    publication = EventRail.publish(SurfaceFixtures::Placed.new(order_id: "o-1"))

    assert_enqueued_jobs 1
    assert_enqueued_with(job: SurfaceFixtures::OnPlaced, args: [ publication.event ])

    perform_enqueued_jobs

    assert_performed_jobs 1
    assert_performed_with(job: SurfaceFixtures::OnPlaced, args: [ publication.event ])
  end

  # `EventRail::TestHelper` is deliberately absent from this list. The exclusion is on
  # asserting, observing, and contract testing, none of which it does: it opens a
  # declaration window and activates a fixture, and Active Job's own helpers remain the
  # only assertion surface. It is also not loaded by requiring the library, which
  # `test_fixture_declaration_test.rb` proves in a subprocess.
  test "EventRail exposes no assertion, observer, or contract-test helper API" do
    %i[
      assert_published assert_event_published assertions
      observe observer subscribe on_event contract_test conformance
    ].each do |name|
      refute EventRail.respond_to?(name), "EventRail must not expose #{name}"
      refute EventRail.const_defined?(name.to_s.to_sym), "EventRail must not define #{name}" if
        name.to_s.start_with?(/[A-Z]/)
    end
  end

  test "the test helper adds no assertions of its own" do
    added = EventRail::TestHelper.instance_methods(false) +
      EventRail::TestHelper.singleton_methods(false)

    assert_equal [ :declare, :with_subscribers ], added.sort
  end

  # --- 8.3 fixed constants and the absence of configuration ---------------------

  test "safety limits are fixed documented constants" do
    {
      MAX_IDENTIFIER_BYTES: 512,
      MAX_SOURCE_BYTES: 255,
      MAX_EVENT_TYPE_BYTES: 255,
      MAX_EXTENSION_ENTRIES: 32,
      MAX_EXTENSION_KEY_BYTES: 64,
      MAX_EXTENSION_VALUE_BYTES: 1_024,
      MAX_EXTENSIONS_BYTES: 8_192,
      MAX_RAW_DEPTH: 32
    }.each do |name, value|
      assert_equal value, EventRail::Limits.const_get(name), "#{name} is a documented fixed limit"
    end

    assert_equal "_aj_", EventRail::Limits::ACTIVE_JOB_RESERVED_KEY_PREFIX
    assert_predicate EventRail::Limits::RESERVED_EXTENSION_KEYS, :frozen?
  end

  test "there is nothing to configure and nothing to generate" do
    %i[configure config setup install! reset_configuration middleware use_middleware].each do |name|
      refute EventRail.respond_to?(name), "EventRail must not expose #{name}"
    end

    refute EventRail.const_defined?(:Configuration)
    refute EventRail.const_defined?(:Generators)
    refute EventRail.const_defined?(:Middleware)
    assert_empty Dir.glob(File.expand_path("../../lib/generators", __dir__)),
      "v1 ships no generators"
    assert_empty EventRail::Railtie.instance_variable_get(:@generators).to_a,
      "the Railtie registers no generators"
  end

  test "there is no public registry query and no diagnostic command" do
    %i[registry subscribers subscribers_for contracts event_classes prepared? doctor diagnose].each do |name|
      refute EventRail.respond_to?(name), "EventRail must not expose #{name}"
    end

    assert_raises(NameError) { EventRail::Internal }
  end

  test "the entire public surface is small enough to read" do
    assert_equal(
      %i[publish with_context],
      (EventRail.singleton_methods(false) - Object.singleton_methods(false)).sort
    )
  end

  test "the whole job integration is one explicit inclusion" do
    readme = File.read(File.expand_path("../../README.md", __dir__))

    assert_includes readme, "include EventRail::JobContext"
    refute_includes readme, "EventRail.configure"
    refute_includes readme, "rails generate event_rail"
  end

  # `config.event_rail.roots` is the one configuration option, and it is documented. There is
  # still no `EventRail.configure`, no generated initializer, and no install generator: the
  # option is a filter over roots Zeitwerk already has, in the same family as
  # `config.autoload_once_paths`, not a second place to configure loading.
  test "the only configuration is the discovery roots" do
    readme = File.read(File.expand_path("../../README.md", __dir__))

    assert_includes readme, "config.event_rail.roots"
    assert_equal [ :roots ], Rails.application.config.event_rail.keys
  end

  # --- 8.6 every failure comes from one hierarchy -------------------------------

  test "every public error descends from EventRail::Error" do
    error_classes.each do |error_class|
      assert_operator error_class, :<, EventRail::Error, "#{error_class} must descend from EventRail::Error"
      assert_operator error_class, :<, StandardError
    end
  end

  test "the hierarchy covers every documented failure" do
    expected = %w[
      CastingError ConfigurationError DeclarationError DuplicateContractError DuplicatePublicationError
      EnqueueError
      InvalidContext InvalidContract InvalidData InvalidEnvelope InvalidEvent InvalidMetadata
      NotReadyError PublicationError RetryPayloadMismatchError SerializationError
      TransactionalPublicationError UnexpectedEventError UnknownEventTypeError UnsupportedEventVersionError
      UnsupportedFormatError
    ]

    assert_equal expected, error_classes.map { |error_class| error_class.name.split("::").last }.sort
  end

  test "errors expose stable diagnostic fields and never an internal object" do
    error = assert_raises(EventRail::EnqueueError) do
      SurfaceFixtures::OnPlaced.stub(:perform_later, ->(*) { raise "adapter exploded" }) do
        EventRail.publish(SurfaceFixtures::Placed.new(order_id: "o-1"))
      end
    end

    assert_kind_of EventRail::Event, error.event
    assert_equal SurfaceFixtures::OnPlaced, error.failed_subscriber
    assert_instance_of RuntimeError, error.cause

    error_classes.each do |error_class|
      exposed = error_class.instance_methods(false).grep_v(/=\z/)
      exposed.each do |name|
        refute_match(/registry|serializer|snapshot|execution|job_instance/, name.to_s,
          "#{error_class}##{name} exposes internal state")
      end
    end
  end

  test "a declaration, event, context, envelope, and readiness failure all use the hierarchy" do
    assert_raises(EventRail::DeclarationError) { Class.new(EventRail::Event) { attribute :freeze, :string } }
    assert_raises(EventRail::InvalidEvent) { SurfaceFixtures::Placed.new(order_id: "o-1", nope: 1) }
    assert_raises(EventRail::CastingError) { SurfaceFixtures::Placed.new(order_id: 1) }
    assert_raises(EventRail::InvalidContext) { EventRail.with_context(message_id: "") { } }
    assert_raises(EventRail::InvalidEnvelope) { EventRail::Envelope.of(Object.new) }
    assert_raises(EventRail::UnexpectedEventError) { SurfaceFixtures::OnPlaced.new("nope").perform_now }
  end

  private
    def error_classes
      EventRail.constants
        .map { |name| EventRail.const_get(name) }
        .grep(Class)
        .select { |candidate| candidate < EventRail::Error }
        .sort_by(&:name)
    end

    def capture(names)
      captured = {}
      subscriptions = names.map do |name|
        ActiveSupport::Notifications.subscribe(name) do |*args|
          (captured[name] ||= []) << ActiveSupport::Notifications::Event.new(*args).payload
        end
      end
      yield
      captured
    ensure
      subscriptions.each { |subscription| ActiveSupport::Notifications.unsubscribe(subscription) }
    end
end
