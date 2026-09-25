module Payments
  # Releases an authorization that will never be captured. Enqueued by Api.void. A payment
  # already captured is not voided -- its caller refunds it instead.
  class VoidJob < PaymentJob
    private
      def attempt(payment)
        return unless payment.authorized?

        gateway.void(idempotency_key: "void-#{payment.reference}", authorization_code: payment.authorization_code)
        payment.transition!(from: "authorized", to: "voided", voided_at: Time.current)
      end

      def report(payment)
        publish Events::AuthorizationVoided.new(reference: payment.reference) if payment.voided?
      end

      # An authorization nobody can void expires at the card issuer on its own after days;
      # there is nothing further to report.
      def give_up(_error) = nil
  end
end
