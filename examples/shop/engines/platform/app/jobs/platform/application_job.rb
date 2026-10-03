module Platform
  class ApplicationJob < ActiveJob::Base
    include EventRail::JobContext

    # Later declarations are consulted first, so StandardError is the fallback. No discard_on:
    # Active Job raises DeserializationError for a database blip, not only a deleted record.
    # The backoff's window outlasts every deadline in the shop, so only a deadline gives up.
    retry_on StandardError, wait: :polynomially_longer, attempts: 10
    retry_on Unavailable, ResourceExhausted, *ErrorCategory.framework_errors(Unavailable), wait: :polynomially_longer, attempts: 10
    # A lost race is settled within seconds: the other party finishes, and this run finds it done.
    retry_on Aborted, *ErrorCategory.framework_errors(Aborted), wait: 1.second, attempts: 30
    # An expected failure reaching here went unhandled: re-raised so it fails at once rather than
    # falling through to the StandardError retry.
    rescue_from(*ErrorCategory::EXPECTED, *ErrorCategory::EXPECTED.flat_map { |category| ErrorCategory.framework_errors(category) }) { |error| raise error }

    before_perform do
      Rails.error.set_context(correlation_id: EventRail::Current.correlation_id, causation_id: EventRail::Current.causation_id)
    end

    # Raises if the queue refuses the job, where perform_later returns false and the job is lost
    # unless the caller checks. options: wait:, wait_until:, queue:.
    def self.perform_later!(*arguments, **options)
      job = new(*arguments)
      job.enqueue(options) or raise(job.enqueue_error || ActiveJob::EnqueueError.new("#{name} was not enqueued"))
      job
    end

    # Commits or rolls back with the surrounding transaction; raises ArgumentError outside one.
    def self.stage(*arguments)
      job = new(*arguments)
      StagedJob.stage([ job ])
      job
    end
  end
end
