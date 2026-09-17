require "active_support/core_ext/class/subclasses"
require "monitor"

module EventRail
  module Internal
    # The subscriber registry: a pending list the macro appends to, and an immutable
    # snapshot preparation seals from it.
    #
    # Publication reads the snapshot without taking the lock, so a concurrent rebuild
    # can only ever hand a reader a complete old snapshot or a complete new one. The
    # unprepared state is distinct from a prepared snapshot in which an event happens
    # to have no subscribers: the first is a boot-order bug and raises, the second is a
    # legitimate zero-delivery publication.
    class Registry
      CONVENTIONAL_ROOTS = %w[app/events app/jobs].freeze

      Snapshot = Struct.new(:subscribers, :contracts, keyword_init: true) do
        def subscribers_for(event_class)
          subscribers[event_class] || EMPTY_SUBSCRIBERS
        end

        def event_class_for(event_type, version)
          contracts[[ event_type, version ]]
        end

        def versions_of(event_type)
          contracts.keys.filter_map { |type, version| version if type == event_type }
        end
      end

      EMPTY_SUBSCRIBERS = [].freeze

      @monitor = Monitor.new
      @pending = []
      @snapshot = nil
      @building = false
      # A test declaration window, opened by EventRail::TestHelper.declare. Distinct from
      # @building: a window routes subscriptions to the dormant fixture set rather than to
      # the live pending list, which is what keeps a fixture from fanning out to every
      # later test in the process.
      @window = false
      @fixtures = []
      # Set from `before_class_unload`, which fires first in a reload cycle, and cleared when
      # preparation finishes. Rails deletes the constants and only then runs prepare
      # callbacks, and nothing clears the snapshot in between -- so without this flag the
      # window between the two is indistinguishable from a sealed registry, and a legal
      # declaration arriving there would be rejected for lateness.
      @reloading = false
      # Subscribers activated for the duration of a block, and the snapshot and fixture set
      # to restore when it exits. A stack, so nested activations are additive.
      @active_fixtures = []
      @activations = []

      class << self
        # Appending is idempotent per job class: the macro may be called more than once
        # in one body, and the declarations themselves live on the job class.
        def declare(job_class)
          @monitor.synchronize do
            if @window
              @fixtures << job_class unless @fixtures.include?(job_class)
              next
            end

            if @snapshot && !@building && !@reloading
              raise DeclarationError,
                "#{job_class} declared a subscription after EventRail finished preparing, so it would receive no " \
                "deliveries. Move it under a conventional app/events or app/jobs root, or load it from an " \
                "autoload-once path or plain require before application preparation."
            end

            @pending << job_class unless @pending.include?(job_class)
          end
        end

        # The contract half of the sealing rule, called from the writer form of
        # `EventRail::Event.event_type` and `.version`. A check only: contracts are collected
        # by rescanning `EventRail::Event.descendants` when a snapshot is built, so there is
        # no pending list for events and nothing here to keep reload-safe.
        #
        # Named classes only. An unnamed class can never enter the index -- `build_contracts`
        # selects through `live?`, which resolves the constant the name denotes -- so checking
        # one would reject every inline event definition in a test suite for no guarantee
        # gained.
        def declare_contract(event_class, location = nil)
          return if event_class.name.nil?

          @monitor.synchronize do
            next unless @snapshot
            next if @building || @reloading || @window

            raise DeclarationError,
              "#{event_class}#{" (#{location})" if location} declared an event contract after EventRail finished " \
              "preparing, so a worker could not reconstruct it from the queue. Event classes are discovered only " \
              "from #{CONVENTIONAL_ROOTS.join(" and ")} in the application and its engines: move the file under " \
              "#{CONVENTIONAL_ROOTS.first}. An event class in a gem that is not loaded at boot can be required " \
              "from an initializer. In a test, define it inside EventRail::TestHelper.declare."
          end
        end

        def snapshot
          snapshot = @snapshot
          return snapshot if snapshot

          raise NotReadyError,
            "EventRail has not prepared its subscriber registry yet; publication is only available after " \
            "application preparation"
        end

        def prepared?
          !@snapshot.nil?
        end

        # Marks the start of a reload cycle. Registered once from a Railtie initializer, never
        # from preparation: a callback registered inside `prepare` would be added again on
        # every reload and accumulate for the life of the process.
        def reloading!
          @monitor.synchronize { @reloading = true }
        end

        def reloading?
          @reloading
        end

        def subscribers_for(event_class)
          snapshot.subscribers_for(event_class)
        end

        # Reentrant, because eager loading a conventional root runs macros that call
        # back into `declare`.
        def prepare
          @monitor.synchronize do
            previously_building = @building
            @building = true
            begin
              eager_load_conventional_roots
              prune_stale_declarations
              @snapshot = build_snapshot
            ensure
              @building = previously_building
              # Cleared here rather than from a reloader callback because the two reload paths
              # differ: a console `reload!` runs prepare twice, the executor path that serves a
              # request runs it once. The end of preparation is the only point correct for
              # both. In `ensure`, so a failed prepare does not leave sealing disabled.
              @reloading = false
            end
          end
          @snapshot
        end

        # Internal: opens the pending list for declarations outside preparation. Used by
        # preparation itself and by EventRail's own tests, which define subscriber
        # fixtures after the host application has already been prepared.
        def reopen
          @monitor.synchronize do
            previously_building = @building
            @building = true
            begin
              yield
            ensure
              @building = previously_building
            end
          end
        end

        # Opens a test declaration window. Subscriptions declared inside become dormant
        # fixtures; event contracts declared inside are indexed when the window closes,
        # because `build_contracts` rescans `EventRail::Event.descendants` and a named class
        # stays there for the life of the process.
        #
        # The monitor is held across the yield, as `reopen` does, because a window is opened
        # at file scope before any test runs. `activate` deliberately does not, since it
        # yields to arbitrary test code.
        def declare_fixtures
          @monitor.synchronize do
            unless @activations.empty?
              raise ArgumentError,
                "a declaration window cannot be opened inside with_subscribers, because closing it rebuilds the " \
                "registry and would discard the activation"
            end

            previously = @window
            @window = true
            begin
              yield
            ensure
              @window = previously
            end

            # Rebuilding here is what puts window-declared contracts in the index. Nothing
            # is eager-loaded: the window body has already run.
            @snapshot = build_snapshot(extra_subscribers: @active_fixtures) if @snapshot
          end
        end

        # Activates dormant fixture subscribers for the duration of the block, then restores
        # the previous snapshot. The block runs outside the monitor: a test may spawn a
        # thread that calls `prepare`, and holding the lock across the yield would deadlock
        # it.
        def activate(job_classes)
          restore = nil

          @monitor.synchronize do
            validate_activation!(job_classes)

            # Built before anything is committed: `build_snapshot` applies the same
            # validation preparation does, so an abstract or context-less fixture raises
            # here. Assigning first would leave the failed fixture active for every later
            # activation in the process.
            fixtures = @active_fixtures + job_classes
            candidate = build_snapshot(extra_subscribers: fixtures)

            restore = [ @snapshot, @active_fixtures ]
            @snapshot = candidate
            @active_fixtures = fixtures
            @activations.push(restore)
          end

          begin
            yield
          ensure
            @monitor.synchronize do
              @snapshot, @active_fixtures = restore
              @activations.pop
            end
          end
        end

        def fixtures
          @fixtures.dup.freeze
        end

        def reset!
          @monitor.synchronize do
            @pending = []
            @snapshot = nil
            @building = false
            @window = false
            @reloading = false
            @active_fixtures = []
            @activations = []
            # @fixtures is deliberately not cleared, for the same reason the pending list is
            # pruned rather than emptied: a fixture is declared once at file scope and its
            # window never runs again, so clearing it would leave every later activation in
            # the process unable to find it. Fixtures are dormant, so keeping them changes
            # no snapshot.
          end
        end

        private
          # Rails exposes concrete loader roots for the host and every engine through the
          # main autoloader. Iterating `Rails::Engine.subclasses[*].paths["app/jobs"]`
          # does not work: that path is not exposed that way.
          def eager_load_conventional_roots
            return unless defined?(Rails) && Rails.respond_to?(:autoloaders)

            loader = Rails.autoloaders.main
            return unless loader.respond_to?(:eager_load_dir)

            loader.dirs.each do |dir|
              next unless CONVENTIONAL_ROOTS.any? { |root| dir.end_with?("/#{root}") }
              next unless Dir.exist?(dir)

              begin
                loader.eager_load_dir(dir)
              rescue Zeitwerk::Error
                # An ignored or unmanaged directory is a legitimate application choice,
                # not a reason to fail preparation.
                nil
              end
            end
          end

          # A reload replaces class objects while leaving the previous ones reachable
          # from this list. An entry survives only if the constant its own name denotes
          # is still this exact object, which is what distinguishes a live class from a
          # reloaded class's discarded predecessor. The list is never cleared wholesale,
          # because a declaration in non-reloadable code -- an autoload-once path, or
          # plainly required lib code -- ran its macro once at require time and would be
          # lost on the first rebuild.
          def prune_stale_declarations
            @pending.select! { |job_class| live?(job_class) }
          end

          def live?(klass)
            name = klass.name
            return false if name.nil?

            resolved = begin
              Object.const_get(name)
            rescue NameError
              nil
            end

            resolved.equal?(klass)
          end

          # `extra_subscribers` carries fixtures activated for a block. They are not added to
          # the pending list, so the next rebuild without them drops them again.
          def build_snapshot(extra_subscribers: EMPTY_SUBSCRIBERS)
            contracts = build_contracts
            subscribers = {}

            # The pending list is filtered here, not only pruned by preparation. A snapshot
            # may be built without a preceding prune -- `activate` does exactly that -- and
            # the list can hold an entry whose macro ran before a later argument raised, so
            # a snapshot must never validate a class the constant no longer denotes.
            (@pending.select { |job_class| live?(job_class) } + extra_subscribers).each do |job_class|
              validate_subscriber!(job_class)

              job_class.event_rail_subscriptions.each do |event_class|
                next unless live?(event_class)

                (subscribers[event_class] ||= []) << job_class
              end
            end

            subscribers.each_value { |jobs| jobs.sort_by!(&:name) }
            subscribers.transform_values!(&:freeze)

            Snapshot.new(subscribers: subscribers.freeze, contracts: contracts).freeze
          end

          # Every discovered event class is validated here rather than at first
          # construction, so a broken contract or identity declaration fails the boot
          # that introduced it instead of the first publication that happens to hit it.
          def build_contracts
            discovered = EventRail::Event.descendants.select { |event_class| live?(event_class) }
            concrete = discovered.select { |event_class| event_class.concrete? }

            ContractIndex.build(concrete)
          end

          # These are caller mistakes in a test, not failures of the library's declaration
          # rules, so they raise ArgumentError: an adopter rescuing EventRail::Error should
          # not catch them.
          def validate_activation!(job_classes)
            job_classes.each do |job_class|
              if job_class.name.nil?
                raise ArgumentError,
                  "#{job_class.inspect} has no name, and Active Job cannot enqueue a job it cannot name; " \
                  "assign the class to a constant"
              end

              next if @fixtures.include?(job_class)

              if @pending.include?(job_class)
                raise ArgumentError,
                  "#{job_class} is already a live subscriber; with_subscribers is for fixtures declared in a test"
              end

              raise ArgumentError,
                "#{job_class} was not declared inside EventRail::TestHelper.declare, so with_subscribers cannot " \
                "activate it"
            end
          end

          def validate_subscriber!(job_class)
            unless job_class.instance_methods(false).include?(:perform) ||
                job_class.private_instance_methods(false).include?(:perform)
              raise DeclarationError,
                "#{job_class} declares a subscription but does not define its own perform, so it is abstract"
            end
            unless job_class.subclasses.empty?
              raise DeclarationError,
                "#{job_class} declares a subscription and has subclasses " \
                "(#{job_class.subclasses.map(&:to_s).sort.join(", ")}), so it is abstract; declare the " \
                "subscription on each concrete job instead"
            end
            unless job_class.include?(EventRail::JobContext)
              raise DeclarationError,
                "#{job_class} declares a subscription but does not propagate logical context. Add " \
                "`include EventRail::JobContext` to #{job_class} or to its base class."
            end

            validate_perform_arity!(job_class)
          end

          # Exactly one required positional parameter. A splat or a keyword signature
          # would accept an event by accident and make the delivery contract depend on
          # how the method happens to be written.
          def validate_perform_arity!(job_class)
            parameters = job_class.instance_method(:perform).parameters
            unless parameters.map(&:first) == [ :req ]
              raise DeclarationError,
                "#{job_class}#perform must take exactly one required positional event parameter, " \
                "not #{parameters.inspect}"
            end
          end
      end
    end
  end
end
