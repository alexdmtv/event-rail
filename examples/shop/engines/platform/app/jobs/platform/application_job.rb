module Platform
  # Each module's own ApplicationJob inherits from this one. Including EventRail::JobContext
  # here is EventRail's whole integration: every job in the shop carries its logical context
  # -- correlation, causation, extensions -- into the jobs and events it causes.
  class ApplicationJob < ActiveJob::Base
    include EventRail::JobContext

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
