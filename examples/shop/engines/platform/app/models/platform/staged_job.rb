module Platform
  # Jobs staged in the transaction of the records they belong to; also EventRail's stager
  # (config.event_rail.stager). It checks for a transaction on its own connection only.
  class StagedJob < ApplicationRecord
    # Rows younger than this are still being handed over by the code that staged them.
    GRACE = 5.seconds
    # A row still held after this is not healing on its own, and is reported once.
    STUCK_AFTER = 5.minutes

    # A row whose job class no longer exists is parked: the relay stops retrying it, which would
    # never succeed, and it waits for someone to deploy the class back or remove it.
    scope :waiting, -> { where(parked_at: nil) }
    scope :overdue, -> { waiting.where(created_at: ...GRACE.ago) } # find_each hands them over oldest first

    # One statement, so the list is staged whole or not at all even if the caller rescues and
    # commits; insert_all! because insert_all would skip a conflicting row silently. Raises
    # ArgumentError outside a transaction, checked first so an empty list is refused too.
    def self.stage(jobs)
      raise ArgumentError, "staging needs a surrounding transaction to commit with" unless current_transaction.open?
      return if jobs.empty?

      now = Time.current
      insert_all!(jobs.map do |job|
        { job_id: job.job_id, job_class: job.class.name, payload: job.serialize,
          correlation_id: EventRail::Current.correlation_id, causation_id: EventRail::Current.message_id,
          trace_context: Traces.carrier, created_at: now }
      end)

      # After every open transaction, not just this connection's: the enqueue is then immediate
      # whatever Active Job's deferral setting, so a row is never deleted for a deferred one.
      # Nothing may raise to the caller, which has committed; a failure is left for the relay.
      job_ids = jobs.map(&:job_id)
      ActiveRecord.after_all_transactions_commit do
        where(job_id: job_ids).find_each do |staged|
          staged.hand_over
        rescue => error
          staged.hold(error)
        end
      rescue => error
        jobs.each { |job| held(job.job_id, job.class.name, error, EventRail::Current.correlation_id) }
      end
    end

    # A job left for the relay. Logged every time, as the relay retries every second; reported as
    # an error only once it stops healing (hold).
    def self.held(job_id, job_class, error, correlation_id)
      Rails.event.notify("platform.staged_job_held", staged_job_id: job_id, job_class:, correlation_id:, error_class: error.class.name, reason: error.message)
    end

    # Enqueues the job in the flow it was staged in, and deletes the row; false if the row was kept
    # for the relay. At the commit the job is enqueued in the trace it was staged in; by the relay,
    # in a trace of its own that links to that one (Traces.linked_to). A refused enqueue sets
    # enqueue_error rather than raising, so the row stays; an aborting enqueue callback is the
    # job's own decision, so the row goes. Other errors raise.
    def hand_over
      job = ActiveJob::Base.deserialize(payload)
      in_its_flow { Traces.linked_to(trace_context, "#{job_class} hand over") { job.enqueue } }

      if job.successfully_enqueued?
        delete
      elsif job.enqueue_error
        hold(job.enqueue_error)
        return false
      else
        Rails.event.notify("platform.staged_job_declined", staged_job_id: job_id, job_class:)
        delete
      end
      true
    end

    # Leaves the row for the relay. A job class that no longer exists will never be handed over:
    # the row is parked and reported at once. Anything else is reported once the row has been held
    # past STUCK_AFTER, by whichever attempt first claims the report; at most once, as a crash
    # between the claim and the report loses it, which the outbox's health check still shows.
    def hold(error)
      self.class.held(job_id, job_class, error, correlation_id)
      unknown_class = error.is_a?(ActiveJob::UnknownJobClassError)
      return unless unknown_class || created_at.before?(STUCK_AFTER.ago)

      claim = { reported_at: Time.current }
      claim[:parked_at] = Time.current if unknown_class
      return unless self.class.where(id:, reported_at: nil).update_all(claim) == 1

      Rails.error.report(error, handled: true, severity: :error, context: { details: { staged_job_id: job_id, job_class:, correlation_id:, staged_at: created_at } })
    end

    private
      def in_its_flow(&block)
        return yield if correlation_id.nil? || EventRail::Current.correlation_id

        EventRail.with_context(message_id: causation_id || job_id, correlation_id: correlation_id, &block)
      end
  end
end
