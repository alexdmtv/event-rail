module Payments
  # Releases an authorization that will never be captured -- one never captured, or one
  # whose capture was refused. Enqueued by Api.void. A payment already captured is not voided;
  # Api.release refunds it instead.
  class VoidJob < PaymentJob
    private
      def operation_for(payment) = (:void if payment.voidable?)
      def report(payment) = report_void(payment)
  end
end
