module Orders
  # The payment is captured: the order is paid, and only now is it shipped.
  class MarkPaidJob < ApplicationJob
    subscribes_to Payments::Events::PaymentCaptured

    def perform(event) = Order.find_by(reference: event.reference)&.mark_paid
  end
end
