module Payments
  # Takes the money an authorization holds. Enqueued by Api.capture.
  class CaptureJob < PaymentJob
    private
      def attempt(payment)
        return unless payment.authorized?

        gateway.capture(idempotency_key: "capture-#{payment.reference}", authorization_code: payment.authorization_code, amount_cents: payment.amount_cents)
        payment.transition!(from: "authorized", to: "captured", captured_at: Time.current)
      rescue Gateway::Refused => refusal
        payment.transition!(from: "authorized", to: "capture_failed", failure_reason: refusal.message)
      end

      def report(payment)
        if payment.captured? || payment.refunded? || payment.refund_failed?
          publish Events::PaymentCaptured.new(reference: payment.reference, amount_cents: payment.amount_cents, currency: payment.currency)
        elsif payment.capture_failed?
          publish Events::CaptureFailed.new(reference: payment.reference, reason: payment.failure_reason)
        end
      end

      def give_up(error)
        payment = Payment.find_by!(reference: arguments.first)
        payment.transition!(from: "authorized", to: "capture_failed", failure_reason: "payment provider unavailable: #{error.message}")
        report(payment)
      end
  end
end
