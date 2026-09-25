module Payments
  # Returns captured money to the customer. Enqueued by Api.refund.
  class RefundJob < PaymentJob
    private
      def attempt(payment)
        return unless payment.captured?

        gateway.refund(idempotency_key: "refund-#{payment.reference}", authorization_code: payment.authorization_code, amount_cents: payment.amount_cents)
        payment.transition!(from: "captured", to: "refunded", refunded_at: Time.current)
      rescue Gateway::Refused => refusal
        payment.transition!(from: "captured", to: "refund_failed", failure_reason: refusal.message)
      end

      def report(payment)
        if payment.refunded?
          publish Events::RefundIssued.new(reference: payment.reference, amount_cents: payment.amount_cents, currency: payment.currency)
        elsif payment.refund_failed?
          publish Events::RefundFailed.new(reference: payment.reference, reason: payment.failure_reason)
        end
      end

      def give_up(error)
        payment = Payment.find_by!(reference: arguments.first)
        payment.transition!(from: "captured", to: "refund_failed", failure_reason: "payment provider unavailable: #{error.message}")
        report(payment)
      end
  end
end
