module Platform
  # A job a boundary started in the same transaction as its business records: a web
  # request, the simulator, a scheduled scan -- code with no job of its own whose retry
  # could repeat a lost enqueue. The queue lives in another database, so enqueuing cannot
  # join the transaction; staging can. The records and the job commit together or not at
  # all, and the job is then handed to the queue:
  #
  #   * at once, after the commit (Platform::ApplicationJob.stage_later), and
  #   * by Platform::StagedJobRelayJob, for any row whose immediate hand-over was cut short.
  #
  # The job is stored as Active Job's own serialized form, which already carries its ID and
  # its EventRail context. Handing the same row over twice enqueues the same job twice under
  # one ID: the same command, which every job in the shop treats as a repetition. Its events
  # carry the same IDs as the first run's, because each event declares its identity.
  #
  # The table belongs in the store of the records it commits with. Every module shares one
  # database today; a module given its own store gets a staged-jobs table there.
  class StagedJob < ApplicationRecord
    # Rows younger than this are still being handed over by the request that staged them.
    GRACE = 5.seconds

    scope :overdue, -> { where(created_at: ...GRACE.ago) } # find_each hands them over oldest first

    def self.stage(job)
      create!(job_id: job.job_id, job_class: job.class.name, payload: job.serialize,
        correlation_id: EventRail::Current.correlation_id, causation_id: EventRail::Current.message_id, created_at: Time.current)
    end

    # Enqueues the job within the flow it was staged in, so the flow's records show it under
    # what started it, and deletes the row once the queue has taken the job. False if the
    # row was kept for the relay.
    #
    # Active Job reports a queue that declined the job by returning false with an enqueue
    # error rather than raising; the row then stays for the relay. An enqueue callback that
    # aborted, with no error, is the job's own decision not to run -- as EventRail treats it
    # -- so the row goes, with a warning. Any other error raises and leaves the row.
    def hand_over
      job = ActiveJob::Base.deserialize(payload)
      in_its_flow { job.enqueue }

      if job.successfully_enqueued?
        delete
      elsif job.enqueue_error
        Rails.logger.warn("Staged job #{job_id} not handed over yet: #{job.enqueue_error.class}: #{job.enqueue_error.message}")
        return false
      else
        Rails.logger.warn("Staged job #{job_id} declined by its own enqueue callback; not handing it over")
        delete
      end
      true
    end

    private
      def in_its_flow(&block)
        return yield if correlation_id.nil? || EventRail::Current.correlation_id

        EventRail.with_context(message_id: causation_id || job_id, correlation_id: correlation_id, &block)
      end
  end
end
