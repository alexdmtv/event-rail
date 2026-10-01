module Payments
  module Gateway
    # A stand-in payment provider that always succeeds. Tests that need it to refuse or time
    # out install a scripted adapter instead.
    #
    # Every call takes an idempotency key, as real providers' APIs do: a capture retried
    # after a crash between the provider's answer and our own write must not charge twice.
    # The fake has nothing to deduplicate, but the calls are shaped like the real thing.
    class Fake
      def authorize(idempotency_key:, amount_cents:, currency:) = "auth_#{SecureRandom.hex(6)}"
      def capture(idempotency_key:, authorization_code:, amount_cents:) = nil
      def void(idempotency_key:, authorization_code:) = nil
      def refund(idempotency_key:, authorization_code:, amount_cents:) = nil
    end
  end
end
