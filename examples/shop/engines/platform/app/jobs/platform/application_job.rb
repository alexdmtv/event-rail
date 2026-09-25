module Platform
  # Each module's own ApplicationJob inherits from this one. Including EventRail::JobContext
  # here is EventRail's whole integration: every job in the shop carries its logical context
  # -- correlation, causation, extensions -- into the jobs and events it causes.
  class ApplicationJob < ActiveJob::Base
    include EventRail::JobContext

    # Enqueues a job under an ID the caller derives from its business key, instead of a
    # random one. Two enqueues of the same command then share an ID, and EventRail derives
    # an event's identity from the ID of the job publishing it, so a repeated command
    # republishes its outcome under the same event ID and every subscriber recognises the
    # repetition.
    #
    # Takes Active Job's enqueue options, such as `wait:`.
    def self.perform_later_as(job_id, *arguments, **options)
      job = new(*arguments)
      job.job_id = job_id
      job.enqueue(options)
      job
    end
  end
end
