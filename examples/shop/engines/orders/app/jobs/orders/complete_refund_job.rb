module Orders
  # A refund for a cancelled order has no return, so it completes nothing.
  class CompleteRefundJob < ApplicationJob
    subscribes_to Payments::Events::RefundIssued

    def perform(event) = Return.for_reference(event.reference)&.complete_refund
  end
end
