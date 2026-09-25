module Loyalty
  # A line in a customer's points ledger. The balance is the sum of the lines.
  class Entry < ApplicationRecord
    def self.record(event, kind:, points:)
      insert({ customer_id: event.customer_id, order_id: event.order_id, kind: kind, points: points,
        event_id: event.id, created_at: Time.current }, unique_by: [ :order_id, :kind ])
    end

    def self.points_for(total) = total.amount_cents / 100
  end
end
