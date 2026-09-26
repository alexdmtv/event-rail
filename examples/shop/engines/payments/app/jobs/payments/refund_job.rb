module Payments
  # Returns captured money to the customer. Enqueued by Api.refund.
  class RefundJob < PaymentJob
    private
      def operation_for(payment) = (:refund if payment.refundable?)
      def report(payment) = report_refund(payment)
  end
end
