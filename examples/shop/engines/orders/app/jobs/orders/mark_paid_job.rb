module Orders
  class MarkPaidJob < ApplicationJob
    subscribes_to Payments::Events::PaymentCaptured

    def perform(event) = Order.for_reference(event.reference)&.mark_paid
  end
end
