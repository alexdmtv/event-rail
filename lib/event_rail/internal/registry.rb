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

      class << self
        # Appending is idempotent per job class: the macro may be called more than once
        # in one body, and the declarations themselves live on the job class.
        def declare(job_class)
          @monitor.synchronize do
            if @snapshot && !@building
              raise DeclarationError,
                "#{job_class} declared a subscription after EventRail finished preparing, so it would receive no " \
                "deliveries. Move it under a conventional app/events or app/jobs root, or load it from an " \
                "autoload-once path or plain require before application preparation."
            end

            @pending << job_class unless @pending.include?(job_class)
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

        def reset!
          @monitor.synchronize do
            @pending = []
            @snapshot = nil
            @building = false
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

          def build_snapshot
            contracts = build_contracts
            subscribers = {}

            @pending.each do |job_class|
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
