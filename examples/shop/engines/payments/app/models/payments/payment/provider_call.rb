module Payments
  class Payment
    # Answers with the attributes recording the outcome; a refusal is an answer, a temporary
    # failure raises. The idempotency key makes asking again after a timeout safe.
    class ProviderCall
      def initialize(payment)
        @payment = payment
      end

      def capture
        gateway.capture(idempotency_key: key("capture"), authorization_code: @payment.authorization_code, amount_cents: @payment.amount_cents)
        { state: "captured", captured_at: Time.current }
      rescue Gateway::Refused => refusal
        { state: "capture_failed", failure_reason: refusal.message }
      end

      # A refused capture keeps its state when its hold is voided, so it still reads as refused.
      def void
        gateway.void(idempotency_key: key("void"), authorization_code: @payment.authorization_code)
        { state: @payment.authorized? ? "voided" : @payment.state, voided_at: Time.current }
      rescue Gateway::Refused => refusal
        # An unvoidable authorization expires at the issuer on its own; only report it.
        Rails.error.report(Gateway::Refused.new("could not void payment #{@payment.reference}: #{refusal.message}"), handled: true, severity: :warning)
        {}
      end

      def refund
        gateway.refund(idempotency_key: key("refund"), authorization_code: @payment.authorization_code, amount_cents: @payment.amount_cents)
        { state: "refunded", refunded_at: Time.current }
      rescue Gateway::Refused => refusal
        { state: "refund_failed", failure_reason: refusal.message }
      end

      private
        def gateway = Gateway.current
        def key(operation) = "#{operation}-#{@payment.reference}"
    end
  end
end
