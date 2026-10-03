module Orders
  class CancelRefusedPaymentJob < ApplicationJob
    subscribes_to Payments::Events::CaptureFailed

    def perform(event) = Order.for_reference(event.reference)&.request_cancellation(reason: "payment refused: #{event.reason}")
  end
end
