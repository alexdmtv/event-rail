require "active_support/isolated_execution_state"

module EventRail
  module Internal
    # One publishing execution: a job attempt, or an application boundary block.
    #
    # Publication state belongs to exactly one attempt. It cannot live in
    # `ActiveSupport::CurrentAttributes`, because the Rails executor resets those
    # around `ActiveJob::Base.execute` and nested in-process execution gets no reset,
    # so a subscriber performed inside its publisher -- the test adapter, the inline
    # adapter, any `perform_now` -- would share the publisher's map and could have a
    # legitimate publication rejected as a duplicate in test while succeeding in
    # production.
    #
    # It cannot live in `ActiveSupport::ExecutionContext[:job]` either, which is the
    # mechanism this design originally named. `ActiveJob::Execution#_perform_job`
    # assigns that key and never restores it, so after a nested `perform_now` returns
    # it still points at the inner job: the outer job's next publication would read
    # the inner job's state and derive identity from the inner job's scope. The stack
    # here is pushed and popped by EventRail itself, in an ensure, so a nested
    # execution restores its parent exactly.
    class Execution
      STACK_KEY = :event_rail_executions

      class << self
        def stack
          ActiveSupport::IsolatedExecutionState[STACK_KEY] ||= []
        end

        def current
          stack.last
        end

        def push(execution)
          stack.push(execution)
          execution
        end

        def pop(execution)
          stack.pop if stack.last.equal?(execution)
        end

        def wrap(execution)
          push(execution)
          yield execution
        ensure
          pop(execution)
        end
      end

      attr_reader :job_class, :scope, :started_at

      # `job_class` is nil for a boundary block. That is what separates the two: a
      # boundary supplies an occurrence time and lineage but derives no identity, so
      # an event published there still receives a random ID, and no duplicate check
      # applies outside a job attempt.
      def initialize(job_class: nil, scope: nil, started_at: nil)
        @job_class = job_class
        @scope = scope
        @started_at = started_at
        @publications = {}
      end

      def derives_identity?
        !job_class.nil? && !scope.nil?
      end

      def record(key)
        @publications[key]
      end

      def record!(key, event:, succeeded:)
        @publications[key] = Record.new(event: event, succeeded: succeeded)
      end

      # What one logical publication looked like the last time this attempt tried it.
      # Retaining the failed case is what lets the same attempt retry complete fanout
      # under the identity it already stamped, instead of manufacturing a second one.
      Record = Struct.new(:event, :succeeded, keyword_init: true) do
        def succeeded?
          succeeded
        end
      end
    end
  end
end
