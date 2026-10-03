module Orders
  # A delivered order coming back, whole. Every step is safe to repeat.
  class Return < ApplicationRecord
    belongs_to :order

    # Its bang methods (refunded!) skip the return's transitions; never call them.
    enum :state, %w[ requested received refunded refund_failed ].index_by(&:itself), validate: true

    # nil for a reference with no return, such as a cancelled order's refund.
    def self.for_reference(reference) = joins(:order).find_by(orders_orders: { reference: reference })

    def request_pickup_later = RequestReturnPickupJob.stage(self)

    # Answered by ReturnReceived (receive).
    def request_pickup = (Fulfillment::Api.request_return_pickup(reference: order.reference) if requested?)

    # The release makes Payments refund the capture. Answered by RefundIssued (complete_refund)
    # or RefundFailed (Order#flag_refused_refund).
    def receive
      update_if({ state: "requested" }, state: "received", received_at: Time.current)
      return unless received?

      Catalog::Api.restock(reservation_id: order.reference)
      Payments::Api.request_release(reference: order.reference)
    end

    def complete_refund
      update_if({ state: "received" }, state: "refunded", refunded_at: Time.current) do
        EventRail.stage(order.announcements.refunded)
      end
    end

    def record_refund_failure(reason)
      update_if({ state: "received" }, state: "refund_failed", failure_reason: "refund refused: #{reason}")
    end
  end
end
