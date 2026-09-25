module Payments
  # Payments' public surface.
  #
  # `authorize` is synchronous: checkout cannot tell the customer "card declined" later.
  # `capture`, `void` and `refund` are asynchronous commands: they return at once, a
  # Payments job talks to the provider -- retrying when it times out -- and the outcome
  # arrives as one of Payments::Events. The caller owns the decision to move money; Payments
  # owns how, and when it has happened.
  module Api
    Payment = Data.define(:reference, :state, :amount_cents, :currency, :failure_reason)

    class Error < StandardError; end
    # The card issuer declined the authorization.
    class Declined < Error; end
    # The provider did not answer; the caller may try again.
    class Unavailable < Error; end

    class << self
      # Places a hold of the amount on the customer's card. Repeating it for the same
      # reference returns the existing authorization rather than holding the amount twice.
      def authorize(reference:, amount_cents:, currency:)
        if (existing = Payments::Payment.find_by(reference: reference))
          return value(existing)
        end

        code = Gateway.current.authorize(idempotency_key: "authorize-#{reference}", amount_cents: amount_cents, currency: currency)
        value(Payments::Payment.create!(reference: reference, amount_cents: amount_cents, currency: currency, state: "authorized", authorization_code: code))
      rescue Gateway::Refused => refusal
        raise Declined, refusal.message
      rescue Gateway::TemporaryFailure => failure
        raise Unavailable, failure.message
      end

      # Each command enqueues under an ID derived from the reference: see
      # Platform::ApplicationJob.perform_later_as.
      def capture(reference:) = enqueue(CaptureJob, "capture", reference)
      def void(reference:) = enqueue(VoidJob, "void", reference)
      def refund(reference:) = enqueue(RefundJob, "refund", reference)

      def payment(reference)
        payment = Payments::Payment.find_by(reference: reference)
        payment && value(payment)
      end

      # The payments for many references at once, by reference.
      def payments(references) = Payments::Payment.where(reference: references).to_h { |payment| [ payment.reference, value(payment) ] }

      private
        def enqueue(job_class, command, reference)
          job_class.perform_later_as("payments-#{command}-#{reference}", reference)
          nil
        end

        def value(payment)
          Payment.new(reference: payment.reference, state: payment.state, amount_cents: payment.amount_cents,
            currency: payment.currency, failure_reason: payment.failure_reason)
        end
    end
  end
end
