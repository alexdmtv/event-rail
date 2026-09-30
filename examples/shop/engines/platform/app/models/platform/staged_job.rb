module Platform
  # The shop's stager: jobs a boundary started in the same transaction as its business records,
  # whether a domain method staged one of its own (Platform::ApplicationJob.stage) or
  # EventRail.stage staged an event's subscribers (config.event_rail.stager names this class).
  # The code staging them is a web request, the simulator, a scheduled scan, or a job -- code
  # whose own retry cannot be relied on to repeat a lost enqueue. The queue lives in another
  # database, so enqueuing cannot join the transaction; staging can. The records and the jobs
  # commit together or not at all, and the jobs are then handed to the queue:
  #
  #   * at once, once every open transaction has committed, and
  #   * by Platform::StagedJobRelayJob, for any row whose immediate hand-over was cut short.
  #
  # A job is stored as Active Job's own serialized form, which already carries its ID and its
  # EventRail context. Handing the same row over twice enqueues the same job twice under one ID:
  # the same command, which every job in the shop treats as a repetition, or the same event
  # delivery, which every subscriber treats as one. Events keep their IDs, because each event
  # declares its identity.
  #
  # The table belongs in the store of the records it commits with. Every module shares one
  # database today, so this one table serves them all, and stage checks for a transaction on
  # this model's connection. A module moved to a store of its own would need a staged-jobs table
  # there, and a stager that routes each staging to the store whose transaction is open.
  class StagedJob < ApplicationRecord
    # Rows younger than this are still being handed over by the request that staged them.
    GRACE = 5.seconds

    scope :overdue, -> { where(created_at: ...GRACE.ago) } # find_each hands them over oldest first

    # Writes every job in one statement, so the list is staged whole or not at all even when the
    # caller rescues the error and commits. The table has no unique index beyond its primary key,
    # so nothing conflicts today; insert_all! rather than insert_all keeps it that way if one is
    # added, since insert_all would skip a conflicting row without saying so. Refused outside a
    # transaction, and before anything else, so an empty list is refused too: a staging with
    # nothing to commit with is a bug at the call site, whatever it stages.
    def self.stage(jobs)
      raise ArgumentError, "staging needs a surrounding transaction to commit with" unless current_transaction.open?
      return if jobs.empty?

      now = Time.current
      insert_all!(jobs.map do |job|
        { job_id: job.job_id, job_class: job.class.name, payload: job.serialize,
          correlation_id: EventRail::Current.correlation_id, causation_id: EventRail::Current.message_id, created_at: now }
      end)

      # Once every open transaction has committed, not just this connection's: enqueuing is
      # then immediate whatever Active Job's deferral setting says, so a row is never deleted
      # for an enqueue that was only deferred. Nothing raised here may reach the caller, whose
      # transaction has already committed: a row whose hand-over fails is left for the relay,
      # and so is every row when reading them back fails.
      job_ids = jobs.map(&:job_id)
      ActiveRecord.after_all_transactions_commit do
        where(job_id: job_ids).find_each do |staged|
          staged.hand_over
        rescue => error
          Rails.logger.warn("Staged job #{staged.job_id} left for the relay: #{error.class}: #{error.message}")
        end
      rescue => error
        Rails.logger.warn("Staged jobs #{job_ids.join(", ")} left for the relay: #{error.class}: #{error.message}")
      end
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
