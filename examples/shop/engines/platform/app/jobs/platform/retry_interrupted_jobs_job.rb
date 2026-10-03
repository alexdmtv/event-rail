module Platform
  # Solid Queue fails a dead worker's jobs with ProcessPrunedError outside the job, where no
  # retry_on sees it. A job that kills its worker every time is retried every run until a person discards it.
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
