module Payments
  class Payment
    # What other modules hear when a provider call is answered.
    class Announcements
      def initialize(payment)
        @payment = payment
      end

      # nil for a refused void, which nobody waits on.
      def for(call)
        case [ call.kind, call.state ]
        in [ "capture", "succeeded" ] then Events::PaymentCaptured.new(**money)
        in [ "capture", "refused" ] then Events::CaptureFailed.new(reference:, reason: call.failure_reason)
        in [ "void", "succeeded" ] then Events::AuthorizationVoided.new(reference:)
        in [ "void", "refused" ] then nil
        in [ "refund", "succeeded" ] then Events::RefundIssued.new(**money)
        in [ "refund", "refused" ] then Events::RefundFailed.new(reference:, reason: call.failure_reason)
        end
      end

      private
        def reference = @payment.reference
        def money = { reference:, amount_cents: @payment.amount_cents, currency: @payment.currency }
    end
  end
end
