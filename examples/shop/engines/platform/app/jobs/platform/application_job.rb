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

    # Starts a job as part of the surrounding transaction, for code at a boundary that has
    # just written business records: the job is staged in their store and commits, or rolls
    # back, with them (see Platform::StagedJob). Once the transaction has committed, the job
    # is handed to the queue at once; if that fails, Platform::StagedJobRelayJob hands it over
    # shortly after. Inside a job, call perform_later_as instead: the job's own retry repeats
    # a lost enqueue.
    def self.stage_later_as(job_id, *arguments)
      transaction = StagedJob.current_transaction
      raise ArgumentError, "stage_later_as needs a surrounding transaction to commit with; use perform_later_as" unless transaction.open?

      job = new(*arguments)
      job.job_id = job_id
      staged = StagedJob.stage(job)
      transaction.after_commit do
        staged.hand_over
      rescue => error
        Rails.logger.warn("Staged job #{job_id} left for the relay: #{error.class}: #{error.message}")
      end
      job
    end
  end
end
