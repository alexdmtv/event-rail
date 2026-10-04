module Orders
  # A refused refund is final and the customer is owed money, so it is recorded for a person
  # rather than retried. RecordCancellationRefundFailureJob hears the same event for cancellations.
  class RecordReturnRefundFailureJob < ApplicationJob
    subscribes_to Payments::Events::RefundFailed

    def perform(event) = Return.for_reference(event.reference)&.record_refund_failure(event.reason)
  end
end
