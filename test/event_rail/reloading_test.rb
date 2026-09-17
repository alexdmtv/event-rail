require "test_helper"
require "json"
require "open3"

# Reloading and eager loading are boot-wide behaviors, so they are exercised in
# subprocesses rather than in this process. The fixture's test environment disables
# reloading, and Zeitwerk cannot be switched into a reloading loader after setup, so a
# development-environment child is the only honest way to call `reload!`. Production
# eager loading likewise has to be a real production boot.
class ReloadingTest < ActiveSupport::TestCase
  DUMMY_ROOT = File.expand_path("../dummy", __dir__)

  # --- 5.4 a reload replaces class objects without duplicating subscriptions -----

  test "repeated reloads replace object identities while preserving subscriptions" do
    result = boot("development", <<~RUBY)
      def snapshot_shape
        snapshot = EventRail.const_get(:Internal)::Registry.snapshot
        {
          "subscriptions" => snapshot.subscribers.to_h { |event_class, jobs|
            [ event_class.name, jobs.map(&:name).sort ]
          },
          "contracts" => snapshot.contracts.keys.map { |type, version| "\#{type}/\#{version}" }.sort,
          "object_ids" => snapshot.subscribers.keys.map(&:object_id) +
            snapshot.subscribers.values.flatten.map(&:object_id)
        }
      end

      shapes = [ snapshot_shape ]
      3.times do
        Rails.application.reloader.reload!
        shapes << snapshot_shape
      end
      emit("shapes" => shapes)
    RUBY

    shapes = result.fetch("shapes")
    subscriptions = shapes.map { |shape| shape.fetch("subscriptions") }
    contracts = shapes.map { |shape| shape.fetch("contracts") }

    assert_equal 4, shapes.length
    assert_equal [ subscriptions.first ], subscriptions.uniq,
      "a reload must preserve the same subscription names and counts"
    assert_equal [ contracts.first ], contracts.uniq

    assert_equal(
      [ "Billing::CreateInvoiceJob", "Orders::RecordOrderMetricsJob" ],
      subscriptions.first.fetch("Orders::OrderPlaced")
    )
    assert_equal [ "Host::AuditApplicationStartedJob" ], subscriptions.first.fetch("Host::ApplicationStarted")

    reloadable_ids = shapes.map { |shape| shape.fetch("object_ids") }
    assert_equal 4, reloadable_ids.uniq.length,
      "a reload must install new class objects rather than reusing the unloaded ones"
  end

  test "a reload keeps a plainly required declaration that no reload re-runs" do
    result = boot("development", <<~RUBY)
      def preloaded_subscribers
        EventRail.const_get(:Internal)::Registry.snapshot
          .subscribers_for(Preloaded::LedgerPosted).map(&:name)
      end

      before = preloaded_subscribers
      3.times { Rails.application.reloader.reload! }
      emit("before" => before, "after" => preloaded_subscribers)
    RUBY

    assert_equal [ "Preloaded::OrderAuditJob" ], result.fetch("before")
    assert_equal result.fetch("before"), result.fetch("after"),
      "clearing the pending list wholesale would discard every non-reloadable declaration"
  end

  # --- 5.5 eager loading, engines, and roots the convention does not cover -------

  test "a production boot with eager loading discovers the same registry" do
    result = boot("production", <<~RUBY)
      snapshot = EventRail.const_get(:Internal)::Registry.snapshot
      emit(
        "contracts" => snapshot.contracts.keys.map { |type, version| "\#{type}/\#{version}" }.sort,
        "order_placed" => snapshot.subscribers_for(Orders::OrderPlaced).map(&:name).sort,
        "eager_loaded" => Rails.application.config.eager_load
      )
    RUBY

    assert result.fetch("eager_loaded")
    assert_equal(
      [ "billing.invoice_issued/1", "host.application_started/1", "inventory.stock_depleted/1",
        "orders.order_placed/1", "preloaded.ledger_posted/1" ],
      result.fetch("contracts"),
      "inventory.stock_depleted lives outside every discovery root and is registered only " \
      "because a subscriber in app/jobs names it during preparation"
    )
    assert_equal(
      [ "Billing::CreateInvoiceJob", "Orders::RecordOrderMetricsJob" ],
      result.fetch("order_placed"),
      "an isolated, gem-style engine's subscriber must be discovered in production too"
    )
  end

  test "a reloadable declaration outside a conventional root raises when it loads later" do
    result = boot("development", <<~RUBY)
      discovered = EventRail.const_get(:Internal)::Registry.snapshot
        .subscribers_for(Orders::OrderPlaced).map(&:name).sort

      raised = begin
        LateSubscriber
        nil
      rescue EventRail::DeclarationError => error
        error.message
      end

      emit("discovered" => discovered, "raised" => raised)
    RUBY

    refute_includes result.fetch("discovered"), "LateSubscriber",
      "preparation must not reach outside the conventional roots"
    refute_nil result.fetch("raised"), "a late declaration must raise rather than receive no deliveries"
    assert_match(/app\/events/, result.fetch("raised"))
  end

  # --- the reload window --------------------------------------------------------

  test "a prepare callback ordered ahead of EventRail's may touch discovered constants" do
    result = boot("development", <<~RUBY, env: { "DUMMY_PREPARE_TOUCHES_EVENTS" => "true" })
      # Three reloads. Each one deletes the constants, then runs the application's prepended
      # prepare callback -- which references an event class and a subscriber -- and only then
      # EventRail's own prepare. Without the reload flag the first of those is rejected as a
      # late declaration.
      3.times { Rails.application.reloader.reload! }

      snapshot = EventRail.const_get(:Internal)::Registry.snapshot
      emit(
        "order_placed" => snapshot.subscribers_for(Orders::OrderPlaced).map(&:name).sort,
        "reloading_after" => EventRail.const_get(:Internal)::Registry.reloading?
      )
    RUBY

    assert_equal(
      [ "Billing::CreateInvoiceJob", "Orders::RecordOrderMetricsJob" ],
      result.fetch("order_placed")
    )
    refute result.fetch("reloading_after"), "the flag must be cleared once preparation finishes"
  end

  test "the reload flag is set only between the unload and the rebuild" do
    result = boot("development", <<~RUBY)
      registry = EventRail.const_get(:Internal)::Registry
      observed = []

      Rails.application.reloader.before_class_unload { observed << [ "unload", registry.reloading? ] }
      Rails.application.reloader.to_prepare(prepend: true) { observed << [ "prepare", registry.reloading? ] }

      at_steady_state = registry.reloading?
      Rails.application.reloader.reload!

      emit(
        "steady" => at_steady_state,
        "during" => observed.uniq,
        "after" => registry.reloading?
      )
    RUBY

    refute result.fetch("steady"), "nothing may be reloading at steady state"
    refute result.fetch("after"), "the flag must be cleared once preparation finishes"
    assert_includes result.fetch("during"), [ "prepare", true ],
      "a prepare callback ahead of EventRail's must see the reload in progress"
  end

  test "a late declaration still raises once a reload has completed" do
    result = boot("development", <<~RUBY)
      Rails.application.reloader.reload!

      raised = begin
        LateSubscriber
        nil
      rescue EventRail::DeclarationError => error
        error.class.name
      end

      emit("raised" => raised)
    RUBY

    assert_equal "EventRail::DeclarationError", result.fetch("raised"),
      "the reload flag must not leave sealing disabled"
  end

  # Readiness before the first prepare is a boot-wide state too: in this process the host
  # application is already initialized, and `Registry.reset!` cannot stand in for it,
  # because a declaration required from an initializer runs its macro once and no rebuild
  # re-runs it. So the unprepared registry is observed in a child that stops short of
  # `initialize!`.
  test "publication before the first snapshot raises a distinct not-ready error" do
    result = boot_without_initializing(<<~RUBY)
      before = begin
        EventRail.const_get(:Internal)::Registry.snapshot
        "no error"
      rescue EventRail::NotReadyError => error
        error.class.name
      end

      prepared_before = EventRail.const_get(:Internal)::Registry.prepared?
      Rails.application.initialize!

      emit(
        "before" => before,
        "prepared_before" => prepared_before,
        "prepared_after" => EventRail.const_get(:Internal)::Registry.prepared?
      )
    RUBY

    assert_equal "EventRail::NotReadyError", result.fetch("before")
    refute result.fetch("prepared_before"), "nothing may be prepared before initialization"
    assert result.fetch("prepared_after"), "initialization must prepare the registry"
  end

  private
    # Loads the application definition without running the initializers, so the registry is
    # observable in its unprepared state.
    def boot_without_initializing(script)
      program = <<~RUBY
        require "json"

        def emit(payload)
          STDOUT.write("EVENT_RAIL_RESULT" + JSON.generate(payload) + "\\n")
        end

        require_relative #{File.join(DUMMY_ROOT, "config/application").inspect}

        #{script}
      RUBY

      run_program("test", program)
    end

    def boot(environment, script, env: {})
      program = <<~RUBY
        require "json"

        def emit(payload)
          STDOUT.write("EVENT_RAIL_RESULT" + JSON.generate(payload) + "\\n")
        end

        require_relative #{File.join(DUMMY_ROOT, "config/environment").inspect}

        #{script}
      RUBY

      run_program(environment, program, env)
    end

    def run_program(environment, program, env = {})
      stdout, stderr, status = Open3.capture3(
        { "RAILS_ENV" => environment, "SECRET_KEY_BASE" => "x" * 64 }.merge(env),
        "bundle", "exec", "ruby", "-e", program, chdir: File.expand_path("../..", __dir__)
      )

      assert_predicate status, :success?, "#{environment} boot failed:\n#{stderr}\n#{stdout}"

      line = stdout.lines.find { |candidate| candidate.start_with?("EVENT_RAIL_RESULT") }
      refute_nil line, "no result emitted from the #{environment} boot:\n#{stdout}\n#{stderr}"

      JSON.parse(line.delete_prefix("EVENT_RAIL_RESULT"))
    end
end
