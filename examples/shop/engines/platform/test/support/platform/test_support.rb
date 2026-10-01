module Platform
  # What every module's tests share, included into every test case. Mostly the faults they
  # inject: a queue that refuses jobs, a job that fails its next runs, a method that fails, a
  # method that succeeds and then dies. Each lasts for its block and is undone after it,
  # whatever the block does. And the relay that recovers from a refused queue. It is outside
  # the load paths, so only tests can load it.
  module TestSupport
    # The runs failing_runs has still to fail, by job class name. Every job in the shop passes
    # through this check before it performs; a job with none left performs as usual.
    module FailingRuns
      class Failure < StandardError; end

      mattr_accessor :remaining, default: {}

      Platform::ApplicationJob.around_perform do |job, block|
        left = FailingRuns.remaining[job.class.name]
        if left&.positive?
          FailingRuns.remaining[job.class.name] = left - 1
          raise Failure, "#{job.class.name} failed on purpose"
        end
        block.call
      end
    end

    # Makes the queue refuse every job -- or, with only:, the jobs of those classes -- while
    # the block runs, as a queue that is down would. Returns the block's value; the block is
    # given the list of jobs refused so far.
    def refusing_enqueue(only: nil, error: -> { ActiveJob::EnqueueError.new("queue unavailable") })
      refused = []
      classes = Array(only).map(&:to_s)
      queue_adapter.define_singleton_method(:enqueue) do |job|
        next super(job) if classes.any? && classes.exclude?(job.class.name)

        refused << job
        raise error.call
      end
      queue_adapter.define_singleton_method(:enqueue_at) do |job, timestamp|
        next super(job, timestamp) if classes.any? && classes.exclude?(job.class.name)

        refused << job
        raise error.call
      end
      yield refused
    ensure
      %i[ enqueue enqueue_at ].each do |method|
        queue_adapter.singleton_class.remove_method(method) if queue_adapter.singleton_class.method_defined?(method, false)
      end
    end

    # Makes the named job fail its next `times` runs while the block runs, before its work
    # starts, with an error nobody has classified: its retry policy handles it as it would any
    # such failure. By name, because a module's jobs are private to it. The block is given a
    # lambda that answers how many runs are still to fail.
    def failing_runs(job_class, times)
      FailingRuns.remaining[job_class] = times
      yield -> { FailingRuns.remaining.fetch(job_class) }
    ensure
      FailingRuns.remaining.delete(job_class)
    end

    # Runs the relay once the staged jobs are old enough for it to hand over.
    def relay_staged_jobs = travel(StagedJob::GRACE + 1.second) { StagedJobRelayJob.perform_now }

    # Makes a module's or class's method raise while the block runs.
    def failing(receiver, method_name, message = "#{method_name} failed", &block)
      replacing(receiver, method_name, ->(*, **) { raise message }, &block)
    end

    # Makes a module's or class's method do its work and then raise while the block runs, as
    # if the process died right after the call returned.
    def interrupting_after(receiver, method_name, message = "interrupted after #{method_name}", &block)
      original = receiver.method(method_name)
      replacing(receiver, method_name, ->(*arguments, **options) { original.call(*arguments, **options).then { raise message } }, &block)
    end

    private
      def replacing(receiver, method_name, replacement)
        singleton = receiver.singleton_class
        original = :"__before_fault_#{method_name}"
        singleton.alias_method original, method_name
        singleton.define_method(method_name, &replacement)
        yield
      ensure
        singleton.alias_method method_name, original
        singleton.remove_method original
      end
  end
end
