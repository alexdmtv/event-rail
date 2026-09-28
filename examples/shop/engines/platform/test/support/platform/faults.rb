module Platform
  # The faults every module's tests inject, in one place: a queue that refuses jobs, a method
  # that fails, a method that succeeds and then dies. Each lasts for its block and is undone
  # after it, whatever the block does.
  module Faults
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
