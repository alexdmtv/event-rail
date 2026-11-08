require_relative "publication_recorder"
require_relative "schedule"
require_relative "worker"

module Platform
  # Included into every test case: running jobs as a worker would, recording what EventRail
  # published, the recurring schedule, faults, and watching calls to a public Api. Each fault
  # lasts for its block and is undone after it, whatever the block does.
  module TestSupport
    include PublicationRecorder
    include Schedule
    include Worker

    # The runs failing_runs has still to fail, and how many it did, by job class name.
    module FailingRuns
      class Failure < StandardError; end

      mattr_accessor :remaining, default: {}
      mattr_accessor :failed, default: Hash.new(0)

      Platform::ApplicationJob.around_perform do |job, block|
        name = job.class.name
        if FailingRuns.remaining[name]&.positive?
          FailingRuns.remaining[name] -= 1
          FailingRuns.failed[name] += 1
          raise Failure, "#{name} failed on purpose"
        end
        block.call
      end
    end

    # Makes the queue refuse every job, or only those classes'. Returns the block's value; the
    # block is given the list of jobs refused so far.
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

    # Fails the job's next `times` runs, or :every run, before its work starts, with an
    # unclassified error. A flow test names the job, as a module's jobs are private to it. The block
    # is given a lambda answering how many runs are still to fail. A fault no run met fails the
    # test: such a test proves nothing.
    def failing_runs(job, times)
      name = job.to_s
      FailingRuns.remaining[name] = times == :every ? Float::INFINITY : times
      FailingRuns.failed[name] = 0
      result = yield -> { FailingRuns.remaining.fetch(name) }
      flunk "no run of #{name} was made to fail" if FailingRuns.failed[name].zero?
      result
    ensure
      FailingRuns.remaining.delete(name)
      FailingRuns.failed.delete(name)
    end

    def relay_staged_jobs = travel(StagedJob::GRACE + 1.second) { StagedJobRelayJob.perform_now }

    def failing(receiver, method_name, message = "#{method_name} failed", &block)
      replacing(receiver, method_name, ->(*, **) { raise message }, &block)
    end

    # The method does its work and then raises, as if the process died right after it returned.
    def interrupting_after(receiver, method_name, message = "interrupted after #{method_name}", &block)
      original = receiver.method(method_name)
      replacing(receiver, method_name, ->(*arguments, **options) { original.call(*arguments, **options).then { raise message } }, &block)
    end

    # How many times the block called the method, which still does its work: for a module's public
    # Api, how often another module asks it something.
    def counting_calls(receiver, method_name, &block)
      calls = 0
      original = receiver.method(method_name)
      replacing(receiver, method_name, ->(*arguments, **options) { calls += 1; original.call(*arguments, **options) }, &block)
      calls
    end

    # Runs the hook before each call to the method within the block, as if something else happened
    # just then; the method then does its work.
    def before_calling(receiver, method_name, hook, &block)
      original = receiver.method(method_name)
      replacing(receiver, method_name, ->(*arguments, **options) { hook.call; original.call(*arguments, **options) }, &block)
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
