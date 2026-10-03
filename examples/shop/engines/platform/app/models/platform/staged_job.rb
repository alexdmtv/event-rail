module Platform
  # Jobs staged in the transaction of the records they belong to; also EventRail's stager
  # (config.event_rail.stager). It checks for a transaction on its own connection only.
  class StagedJob < ApplicationRecord
    # Rows younger than this are still being handed over by the code that staged them.
    GRACE = 5.seconds

    scope :overdue, -> { where(created_at: ...GRACE.ago) } # find_each hands them over oldest first

    # One statement, so the list is staged whole or not at all even if the caller rescues and
    # commits; insert_all! because insert_all would skip a conflicting row silently. Raises
    # ArgumentError outside a transaction, checked first so an empty list is refused too.
    def self.stage(jobs)
      raise ArgumentError, "staging needs a surrounding transaction to commit with" unless current_transaction.open?
      return if jobs.empty?

      now = Time.current
      insert_all!(jobs.map do |job|
        { job_id: job.job_id, job_class: job.class.name, payload: job.serialize,
          correlation_id: EventRail::Current.correlation_id, causation_id: EventRail::Current.message_id, created_at: now }
      end)

      # After every open transaction, not just this connection's: the enqueue is then immediate
      # whatever Active Job's deferral setting, so a row is never deleted for a deferred one.
      # Nothing may raise to the caller, which has committed; a failure is left for the relay.
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

    # Enqueues the job in the flow it was staged in and deletes the row; false if the row was kept
    # for the relay. A refused enqueue sets enqueue_error rather than raising, so the row stays; an
    # aborting enqueue callback is the job's own decision, so the row goes. Other errors raise.
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
