module Payments
  # Payments' public surface.
  #
  # `authorize` is synchronous: placing an order must know whether the card was declined.
  # `capture`, `void`, `release` and `refund` are asynchronous commands: they return at once, a
  # Payments job talks to the provider -- retrying when it times out -- and the outcome
  # arrives as one of Payments::Events. The caller owns the decision to move money; Payments
  # owns how, and when it has happened.
  module Api
    Payment = Data.define(:reference, :state, :amount_cents, :currency, :failure_reason, :voided_at)

    class Error < StandardError; end
    # The card issuer declined the authorization.
    class Declined < Error; end
    # The provider did not answer; the caller may try again.
    class Unavailable < Error; end

    class << self
      # Places a hold of the amount on the customer's card. Repeating it for the same
      # reference returns the existing authorization rather than holding the amount twice,
      # and two calls racing for one reference end with one payment: the provider sees one
      # idempotency key, and the loser of the insert returns the winner's payment.
      def authorize(reference:, amount_cents:, currency:)
        if (existing = Payments::Payment.find_by(reference: reference))
          return value(existing)
        end

        code = Gateway.current.authorize(idempotency_key: "authorize-#{reference}", amount_cents: amount_cents, currency: currency)
        value(Payments::Payment.create_or_find_by!(reference: reference) do |payment|
          payment.assign_attributes(amount_cents: amount_cents, currency: currency, state: "authorized", authorization_code: code)
        end)
      rescue Gateway::Refused => refusal
        raise Declined, refusal.message
      rescue Gateway::TemporaryFailure => failure
        raise Unavailable, failure.message
      end

      def capture(reference:) = enqueue(CaptureJob, reference)
      def void(reference:) = enqueue(VoidJob, reference)
      def refund(reference:) = enqueue(RefundJob, reference)

      # Gives back whatever the payment holds when the command runs: refunds it if it was
      # captured, voids it if it was not. For a caller undoing its payment without knowing
      # whether a capture has landed. Like every command here, it may be sent for a reference
      # with no payment, and then does nothing.
      def release(reference:) = enqueue(ReleaseJob, reference)

      def payment(reference)
        payment = Payments::Payment.find_by(reference: reference)
        payment && value(payment)
      end

      # The payments for many references at once, by reference.
      def payments(references) = Payments::Payment.where(reference: references).to_h { |payment| [ payment.reference, value(payment) ] }

      private
        # perform_later returns false, rather than raising, when the queue refuses the job;
        # the caller must hear it, so that its own retry sends the command again.
        def enqueue(job_class, reference)
          job = job_class.new(reference)
          job.enqueue or raise(job.enqueue_error || ActiveJob::EnqueueError.new("#{job_class} was not enqueued"))
          nil
        end

        def value(payment)
          Payment.new(reference: payment.reference, state: payment.state, amount_cents: payment.amount_cents,
            currency: payment.currency, failure_reason: payment.failure_reason, voided_at: payment.voided_at)
        end
    end
  end
end
