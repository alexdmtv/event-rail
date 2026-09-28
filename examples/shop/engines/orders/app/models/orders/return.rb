module Orders
  # A delivered order coming back, whole: requested, then received at the warehouse, then
  # refunded -- or refund_failed, when the card issuer refuses the refund, for a person to
  # resolve. Every step is safe to repeat.
  class Return < ApplicationRecord
    STATES = %w[ requested received refunded refund_failed ].freeze

    belongs_to :order

    validates :state, inclusion: { in: STATES }

    STATES.each { |state| define_method(:"#{state}?") { self.state == state } }

    def self.for_reference(reference) = joins(:order).find_by(orders_orders: { reference: reference })

    def collect_later = CollectReturnJob.stage_later(self)

    # Asks the carrier to bring the parcel back.
    def collect = (Fulfillment::Api.request_return_pickup(reference: order.reference) if requested?)

    # The parcel is back: its items go back on the shelf and the customer's money goes back to
    # their card. The refund is reported by Payments.
    def receive
      update_if({ state: "requested" }, state: "received", received_at: Time.current)
      return unless received?

      Catalog::Api.restock(reservation_id: order.reference)
      Payments::Api.request_refund(reference: order.reference)
    end

    def complete_refund
      update_if({ state: "received" }, state: "refunded", refunded_at: Time.current)
      EventRail.publish(Events::OrderRefunded.new(**order.event_attributes, total: order.event_total)) if refunded?
    end

    # Retrying will not change the issuer's mind, and the customer is owed money.
    def record_refund_failure(reason)
      update_if({ state: "received" }, state: "refund_failed", failure_reason: "refund refused: #{reason}")
    end
  end
end
