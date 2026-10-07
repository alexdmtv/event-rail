module Platform
  # Included into every test case. Each fault lasts for its block and is undone after it,
  # whatever the block does.
  module TestSupport
    # The runs failing_runs has still to fail, by job class name.
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

    # Fails the named job's next `times` runs, before its work starts, with an unclassified error.
    # By name, because a module's jobs are private to it. The block is given a lambda answering
    # how many runs are still to fail.
    def failing_runs(job_class, times)
      FailingRuns.remaining[job_class] = times
      yield -> { FailingRuns.remaining.fetch(job_class) }
    ensure
      FailingRuns.remaining.delete(job_class)
    end

    # What a metric recorded during the test, by tags: a counter's count, a gauge's or a
    # histogram's last value.
    def recorded(metric)
      adapter = Yabeda::TestAdapter.instance
      case metric
      when Yabeda::Counter then adapter.counters[metric]
      when Yabeda::Gauge then adapter.gauges[metric]
      when Yabeda::Histogram then adapter.histograms[metric]
      end
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
