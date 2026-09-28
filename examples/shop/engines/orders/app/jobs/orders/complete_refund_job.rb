module Orders
  # The refund for a returned order has been issued. A refund for a cancelled order -- a capture
  # that landed before the cancellation -- completes nothing further: it has no return.
  class CompleteRefundJob < ApplicationJob
    subscribes_to Payments::Events::RefundIssued

    def perform(event) = Return.for_reference(event.reference)&.complete_refund
  end
end
