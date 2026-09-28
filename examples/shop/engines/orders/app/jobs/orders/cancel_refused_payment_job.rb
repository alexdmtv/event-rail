module Orders
  # The card issuer refused the capture: the order cannot be paid, so it is cancelled.
  class CancelRefusedPaymentJob < ApplicationJob
    subscribes_to Payments::Events::CaptureFailed

    def perform(event) = Order.for_reference(event.reference)&.request_cancellation(reason: "payment refused: #{event.reason}")
  end
end
