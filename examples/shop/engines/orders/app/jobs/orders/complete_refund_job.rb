module Orders
  # The refund for a returned order has been issued: the return is complete. A refund for a
  # cancelled order completes nothing further -- the cancellation was already announced.
  class CompleteRefundJob < ApplicationJob
    subscribes_to Payments::Events::RefundIssued

    def perform(event)
      order = Order.find_by(reference: event.reference) or return

      order.transition!(from: "awaiting_return", to: "refunded", refunded_at: Time.current)
      EventRail.publish(Events::OrderRefunded.new(**order.event_attributes, total: order.total)) if order.refunded?
    end
  end
end
