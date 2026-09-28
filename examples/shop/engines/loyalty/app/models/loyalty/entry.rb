module Loyalty
  # A line in a customer's points ledger. The balance is the sum of the lines. One line per
  # order and kind, so a fact delivered twice is counted once.
  class Entry < ApplicationRecord
    # One point per whole euro of a delivered order.
    def self.award(delivered) = record(delivered, kind: "award", points: points_for(delivered.total))

    # A refunded order takes its points back.
    def self.revoke(refunded) = record(refunded, kind: "revoke", points: -points_for(refunded.total))

    def self.points_for(total) = total.amount_cents / 100

    def self.record(event, kind:, points:)
      insert({ customer_id: event.customer_id, order_id: event.order_id, kind: kind, points: points,
        event_id: event.id, created_at: Time.current }, unique_by: [ :order_id, :kind ])
    end
    private_class_method :record
  end
end
