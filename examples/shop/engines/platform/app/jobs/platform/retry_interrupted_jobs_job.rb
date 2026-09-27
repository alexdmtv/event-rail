module Platform
  # Retries the jobs whose worker died while running them. Solid Queue notices a worker that
  # stopped sending heartbeats and marks the jobs it held as failed, with ProcessPrunedError
  # -- outside the job, where no retry_on can see it. Such a job never ran to an outcome, so
  # it is run again, as its own retry would have: every job in the shop is safe to repeat.
  # Any other failure stays in the failed list at /jobs, for a person.
  #
  # Run every minute from config/recurring.yml. A job that kills its worker every time would
  # be retried every minute; it shows in the failed list each time, for a person to discard.
  class RetryInterruptedJobsJob < ActiveJob::Base
    queue_as :default

    INTERRUPTED = "SolidQueue::Processes::ProcessPrunedError"

    def perform
      SolidQueue::FailedExecution.find_each do |failed|
        failed.retry if failed.exception_class == INTERRUPTED
      end
    end
  end
end
