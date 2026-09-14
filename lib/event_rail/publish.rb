require "active_support/notifications"

module EventRail
  class << self
    # Publishes an event: stamps it with identity, source, occurrence time, and
    # lineage, then calls ordinary `perform_later` on each declared subscriber.
    #
    #   publication = EventRail.publish(Orders::OrderPlaced.new(order_id: order.id))
    #
    # Individual enqueue calls, not `perform_all_later`. Bulk enqueue skips each job's
    # own `enqueue` callbacks on several adapters, and those callbacks are exactly where
    # an application puts uniqueness, concurrency, and feature-flag decisions that this
    # design promises stay authoritative.
    #
    # Delivery is at-least-once. Jobs already accepted are not rolled back when a later
    # subscriber's enqueue fails, and the retry repeats complete fanout under the same
    # event ID, so a subscriber may see the same event more than once.
    def publish(event, key: nil)
      Internal::Transaction.check!

      prepared = Internal::Stamping.prepare(event, key: key)
      stamped = prepared.event
      subscribers = Internal::Registry.subscribers_for(stamped.class)

      accepted = []
      skipped = []

      ActiveSupport::Notifications.instrument("publish.event_rail", Internal::Notifications.payload_for(stamped)) do |payload|
        payload[:subscriber_count] = subscribers.length

        subscribers.each do |job_class|
          enqueue_subscriber(job_class, stamped, accepted, skipped)
        end

        payload[:accepted] = accepted.length
        payload[:skipped] = skipped.length
      end

      # Successful once every subscriber was either accepted or deliberately skipped. A
      # skipped delivery is a decision, so treating it as a failure would make one
      # subscriber's guard retry the publisher forever.
      Internal::Stamping.succeeded!(prepared)

      Publication.new(event: stamped, accepted_subscribers: accepted, skipped_subscribers: skipped)
    end

    private
      # Three outcomes, not two. Active Job returns false both when an adapter reports
      # failure and when an enqueue callback aborts, so the return value alone cannot
      # tell a fault from a decision. The job instance can, through `enqueue_error`, and
      # the block form of `perform_later` yields the job even when the call returns
      # false.
      def enqueue_subscriber(job_class, event, accepted, skipped)
        payload = Internal::Notifications.payload_for(event).merge(job_class: job_class.name)

        ActiveSupport::Notifications.instrument("enqueue_subscriber.event_rail", payload) do
          job = nil

          begin
            result = job_class.perform_later(event) { |enqueued| job = enqueued }
          rescue StandardError => cause
            payload[:outcome] = "failed"
            raise enqueue_error(event, job_class, accepted, skipped), cause: cause
          end

          if result == false && job&.enqueue_error
            payload[:outcome] = "failed"
            raise enqueue_error(event, job_class, accepted, skipped), cause: job.enqueue_error
          elsif result == false
            payload[:outcome] = "skipped"
            skipped << job_class
          else
            payload[:outcome] = "accepted"
            accepted << job_class
          end
        end
      end

      def enqueue_error(event, job_class, accepted, skipped)
        EnqueueError.new(
          event: event,
          accepted_subscribers: accepted.dup,
          skipped_subscribers: skipped.dup,
          failed_subscriber: job_class
        )
      end
  end
end
