module Payments
  # Gives back whatever the payment holds, decided when it runs, under the payment's claim:
  # a captured payment is refunded, an uncaptured authorization is voided. Enqueued by
  # Api.release. A caller undoing its payment -- a cancelled order -- need not know whether a
  # capture has already landed; Payments does.
  class ReleaseJob < PaymentJob
    private
      def operation_for(payment)
        if payment.refundable? then :refund
        elsif payment.voidable? then :void
        end
      end

      def report(payment)
        payment.refunded? || payment.refund_failed? ? report_refund(payment) : report_void(payment)
      end
  end
end
