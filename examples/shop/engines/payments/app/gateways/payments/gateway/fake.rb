module Payments
  module Gateway
    # A stand-in payment provider whose failures are dialled up from the developer console
    # through Platform's fault settings. With every rate at zero it always succeeds.
    #
    # Every call takes an idempotency key, as real providers' APIs do: a capture retried
    # after a crash between the provider's answer and our own write must not charge twice.
    # The fake has nothing to deduplicate, but the calls are shaped like the real thing.
    class Fake
      def authorize(idempotency_key:, amount_cents:, currency:)
        fail_temporarily_sometimes
        raise Refused, "card declined" if Platform::FaultSettings.roll?(:authorization_decline_rate)

        "auth_#{SecureRandom.hex(6)}"
      end

      def capture(idempotency_key:, authorization_code:, amount_cents:)
        fail_temporarily_sometimes
        raise Refused, "capture refused by the card issuer" if Platform::FaultSettings.roll?(:capture_refusal_rate)
      end

      def void(idempotency_key:, authorization_code:)
        fail_temporarily_sometimes
      end

      def refund(idempotency_key:, authorization_code:, amount_cents:)
        fail_temporarily_sometimes
        raise Refused, "refund refused by the card issuer" if Platform::FaultSettings.roll?(:refund_refusal_rate)
      end

      private
        def fail_temporarily_sometimes
          raise TemporaryFailure, "payment provider timed out" if Platform::FaultSettings.roll?(:temporary_failure_rate)
        end
    end
  end
end
