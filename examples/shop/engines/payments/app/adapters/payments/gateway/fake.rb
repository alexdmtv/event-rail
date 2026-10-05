module Payments
  module Gateway
    # A stand-in provider that always succeeds. Like a real one, it answers a repeated
    # idempotency key the same way.
    class Fake
      def authorize(idempotency_key:, amount_cents:, currency:) = "auth_#{Digest::SHA256.hexdigest(idempotency_key).first(12)}"
      def capture(idempotency_key:, authorization_code:, amount_cents:) = nil
      def void(idempotency_key:, authorization_code:) = nil
      def refund(idempotency_key:, authorization_code:, amount_cents:) = nil
    end
  end
end
