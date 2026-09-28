module Notifications
  # A message sent to a customer about their order: one per order and kind of fact, so a fact
  # delivered twice, or under two identities, is sent once.
  class Notification < ApplicationRecord
    # A notice about something that happened longer ago than this is not worth sending: after an
    # outage, a replayed "your order shipped" from yesterday would only confuse.
    STALE_AFTER = 1.hour

    scope :recent, -> { order(created_at: :desc) }

    def self.send_for(event)
      return if event.occurred_at < STALE_AFTER.ago

      kind, subject, body = Message.for(event)
      insert({ event_id: event.id, kind: kind, order_id: event.order_id, customer_email: event.customer_email,
        subject: subject, body: body, created_at: Time.current }, unique_by: [ :order_id, :kind ])
    end
  end
end
