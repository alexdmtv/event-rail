module Platform
  # Each module's own ApplicationJob inherits from this one. Including EventRail::JobContext
  # here is EventRail's whole integration: every job in the shop carries its logical context
  # -- correlation, causation, extensions -- into the jobs and events it causes.
  class ApplicationJob < ActiveJob::Base
    include EventRail::JobContext

    # The shop's one retry policy, chosen by an error's category (see Platform::ErrorCategory).
    # A job declares none of its own: giving up is a business decision, taken in the domain,
    # usually as a deadline a sweep enforces, never by counting a job's attempts.
    #
    # Waits double from two seconds up to a minute. That is short for production and chosen for
    # the demonstration: a retry is something to watch in the console.
    BACKOFF = ->(executions) { [ 2**executions, 60 ].min.seconds }

    # Later declarations are consulted first.
    #
    # An error with no category is a bug, or a failure nobody has classified yet: it is retried,
    # and left in the failed-jobs list once the attempts run out.
    retry_on StandardError, wait: BACKOFF, attempts: 10
    retry_on Unavailable, ResourceExhausted, *ErrorCategory.framework_errors(Unavailable), wait: BACKOFF, attempts: 10
    # A lost race is settled within seconds: the other party finishes, and this run finds it done.
    retry_on Aborted, *ErrorCategory.framework_errors(Aborted), wait: 1.second, attempts: 30
    # An expected failure reaching the job's edge means the code did not handle it: it fails at once,
    # into the failed-jobs list, rather than retrying what cannot change.
    rescue_from(*ErrorCategory::EXPECTED, *ErrorCategory::EXPECTED.flat_map { |category| ErrorCategory.framework_errors(category) }) { |error| raise error }
    # Only the job's own subject being gone discards it. Any other missing record is a failure
    # to see, not to drop.
    discard_on ActiveJob::DeserializationError

    # Every error a job reports carries the flow it happened in, so it leads to the order's
    # tree in the console.
    before_perform do
      Rails.error.set_context(correlation_id: EventRail::Current.correlation_id, causation_id: EventRail::Current.causation_id)
    end

    # Demonstration only: the developer console can make a chosen job fail its next few runs,
    # to show that job alone retrying while the rest of the shop carries on. The failure is
    # raised where a real one would be, so the job's own retry_on handles it exactly as it
    # would a real failure. A real application has no such switch.
    around_perform do |job, block|
      if Platform::FaultSettings.forced_failures_pending?(job.class) && Platform::FaultSettings.consume_forced_failure(job.class)
        raise InjectedFault, "#{job.class} was told to fail by the developer console"
      end
      block.call
    end

    # Enqueues the job, and raises if the queue refuses it. Active Job's perform_later returns
    # false instead, and a caller that does not check has lost the job without knowing; raising
    # lets the caller's own retry send it again. options: wait:, wait_until:, queue:.
    def self.perform_later!(*arguments, **options)
      job = new(*arguments)
      job.enqueue(options) or raise(job.enqueue_error || ActiveJob::EnqueueError.new("#{name} was not enqueued"))
      job
    end

    # Starts a job as part of the surrounding transaction, for a domain method that has just
    # written its records: the job is staged in their store and commits, or rolls back, with
    # them (see Platform::StagedJob). Once the transaction has committed, the job is handed to
    # the queue at once; if that fails, Platform::StagedJobRelayJob hands it over shortly
    # after. It is right wherever the method runs: in a request, which has no retry, and in a
    # job, where it costs a row and saves nothing but is never wrong.
    def self.stage_later(*arguments)
      transaction = StagedJob.current_transaction
      raise ArgumentError, "stage_later needs a surrounding transaction to commit with" unless transaction.open?

      job = new(*arguments)
      staged = StagedJob.stage(job)
      transaction.after_commit do
        staged.hand_over
      rescue => error
        Rails.logger.warn("Staged job #{job.job_id} left for the relay: #{error.class}: #{error.message}")
      end
      job
    end
  end
end
