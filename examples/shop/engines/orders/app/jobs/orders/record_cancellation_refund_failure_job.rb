module Orders
  # A cancelled order's refund, refused. RecordReturnRefundFailureJob hears the same event for returns.
  class RecordCancellationRefundFailureJob < ApplicationJob
    subscribes_to Payments::Events::RefundFailed

    def perform(event) = Order.cancelled.for_reference(event.reference)&.record_refund_failure(event.reason)
  end
end
