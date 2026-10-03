module Notifications
  # Unique by order and kind rather than event ID, so a fact delivered under two identities is
  # sent once.
  class Notification < ApplicationRecord
    # After an outage, a replayed "your order shipped" from yesterday would only confuse.
    STALE_AFTER = 1.hour

    def self.send_for(event)
      return if event.occurred_at < STALE_AFTER.ago

      kind, subject, body = Message.for(event)
      insert({ event_id: event.id, kind: kind, order_id: event.order_id, customer_email: event.customer_email,
        subject: subject, body: body, created_at: Time.current }, unique_by: [ :order_id, :kind ])
    end
  end
end
