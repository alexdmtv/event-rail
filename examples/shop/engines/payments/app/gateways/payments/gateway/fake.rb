module Payments
  module Gateway
    # A stand-in provider that always succeeds. It ignores the idempotency keys a real
    # provider would deduplicate on.
    class Fake
      def authorize(idempotency_key:, amount_cents:, currency:) = "auth_#{SecureRandom.hex(6)}"
      def capture(idempotency_key:, authorization_code:, amount_cents:) = nil
      def void(idempotency_key:, authorization_code:) = nil
      def refund(idempotency_key:, authorization_code:, amount_cents:) = nil
    end
  end
end
