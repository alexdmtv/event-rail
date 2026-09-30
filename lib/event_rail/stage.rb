require "active_support/notifications"

module EventRail
  class << self
    # Stages an event: stamps it exactly as `publish` does, builds one job per declared
    # subscriber without enqueuing any, and hands them all to the application's stager in one
    # call, inside the caller's database transaction.
    #
    #   Order.transaction do
    #     order.update!(state: "shipped")
    #     EventRail.stage(Orders::OrderShipped.new(order_id: order.id))
    #   end
    #
    # The stager (`config.event_rail.stager`) persists the jobs with that transaction, all or
    # nothing, or raises, and hands them to the queue once it commits. So the intent to
    # deliver commits or rolls back with the state change it reports. Delivery itself is the
    # stager's: its hand-over, its relay, the queue, and each subscriber's own enqueue
    # callbacks, which run when a job is enqueued rather than here.
    #
    # Unlike `publish`, staging inside an open transaction is the point, so there is no
    # transaction check. Whether the right transaction is open is the stager's to judge: only
    # it knows which database it writes to.
    def stage(event, identity: nil, source: nil, **unknown)
      reject_unknown_keywords!(:stage, unknown)

      # Every check that can fail on configuration or readiness runs before stamping, which
      # records the fact in the current execution: a failure here must not leave a record that
      # makes the next staging in the same attempt look like a retry. Readiness before the
      # stager, so staging from an initializer says "not ready" rather than failing to find a
      # class the autoloader cannot load yet.
      configured = Internal::Stager.configured
      snapshot = Internal::Registry.snapshot
      stager = Internal::Stager.resolve(configured)

      prepared = Internal::Stamping.prepare(event, identity: identity, source: source)
      stamped = prepared.event
      handed_over = false

      begin
        jobs = snapshot.subscribers_for(stamped.class).map { |job_class| staged_job(job_class, stamped) }.freeze

        ActiveSupport::Notifications.instrument("stage.event_rail", Internal::Notifications.payload_for(stamped)) do |payload|
          payload[:subscriber_count] = jobs.length
          handed_over = true

          # Called even with no jobs, so the stager's own transaction check applies whether or
          # not the event has subscribers yet: otherwise adding the first one would make a
          # previously silent call site start raising. A copy, so the stager may sort or trim
          # its argument without touching what the result reports.
          stager.stage(jobs.dup)
        end
      ensure
        # A failure before the stager was called -- a subscriber that cannot be built, a
        # notification handler failing as the block starts -- handed nothing over, so it must
        # not leave the fact recorded: the next staging in this attempt is a first staging, not
        # a retry bound to a payload no stager saw. From the stager on, a failure leaves the
        # fact unfinished, and staging it again is a retry.
        Internal::Stamping.abandon!(prepared) unless handed_over
      end

      # After the notification block, as for `publish`.
      Internal::Stamping.succeeded!(prepared)

      StagedPublication.new(event: stamped, staged_jobs: jobs)
    end

    private
      # The job `perform_later` would have built, without the enqueue. Its context entry is
      # built now, while the staging context is current, so the stager may serialize the job
      # whenever and wherever it likes and still write what enqueuing it here would have
      # written. Through the entry alone, not `serialize`: serializing would resolve and
      # memoize the job's queue and priority blocks inside the caller's context and run its
      # argument serializers for nothing. Every subscriber includes JobContext; preparation
      # refuses one that does not.
      def staged_job(job_class, event)
        job_class.new(event).tap { |job| job.send(:__event_rail_entry__) }
      end
  end
end
