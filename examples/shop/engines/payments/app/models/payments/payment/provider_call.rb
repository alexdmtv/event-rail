module Payments
  class Payment
    # One call to the provider for a payment, answering with the attributes that record its
    # outcome. A refusal is an answer; a temporary failure is raised, for the job to retry.
    # Every call carries an idempotency key per payment and operation, so asking again after a
    # timeout returns the provider's real answer rather than acting twice.
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
        # An authorization nobody can void expires at the card issuer on its own after days;
        # there is nothing further to report.
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
