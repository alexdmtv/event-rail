module Orders
  # The card issuer refused the capture: the order cannot be paid, so it is cancelled and its
  # stock released.
  class CancelRefusedPaymentJob < ApplicationJob
    subscribes_to Payments::Events::CaptureFailed

    def perform(event)
      order = Order.find_by(reference: event.reference) or return
      return unless order.placed? || order.cancelled?

      Cancellation.new(order, reason: "payment refused: #{event.reason}").call
    end
  end
end
