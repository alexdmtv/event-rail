module Orders
  # A refused refund is final and the customer is owed money, so it is flagged for a person
  # rather than retried.
  class FlagRefusedRefundJob < ApplicationJob
    subscribes_to Payments::Events::RefundFailed

    def perform(event) = Order.for_reference(event.reference)&.flag_refused_refund(event.reason)
  end
end
