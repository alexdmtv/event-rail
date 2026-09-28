module Payments
  # Payments' public surface.
  #
  # `authorize` decides now: confirming an order must know whether the card was declined.
  # `request_capture`, `request_void`, `request_release` and `request_refund` accept a
  # request: they return at once, a Payments job talks to the provider -- retrying while it
  # does not answer -- and the outcome arrives as one of Payments::Events. The caller owns the
  # decision to move money; Payments owns how, and when it has happened.
  module Api
    Payment = Data.define(:reference, :state, :amount_cents, :currency, :failure_reason, :voided_at)

    class << self
      # Places a hold of the amount on the customer's card; raises Declined or Unavailable.
      # Safe to repeat for a reference.
      def authorize(reference:, amount_cents:, currency:) = value(Payments::Payment.authorize(reference:, amount_cents:, currency:))

      def request_capture(reference:) = Payments::Payment.capture_later(reference).then { nil }
      def request_void(reference:) = Payments::Payment.void_later(reference).then { nil }
      def request_refund(reference:) = Payments::Payment.refund_later(reference).then { nil }

      # Gives back whatever the payment holds when the request is carried out: refunds it if it
      # was captured, voids it if it was not. For a caller undoing its payment without knowing
      # whether a capture has landed. Like every request here, it may be sent for a reference
      # with no payment, and then does nothing.
      def request_release(reference:) = Payments::Payment.release_later(reference).then { nil }

      def payment(reference)
        payment = Payments::Payment.find_by(reference: reference)
        payment && value(payment)
      end

      # The payments for many references at once, by reference.
      def payments(references) = Payments::Payment.where(reference: references).to_h { |payment| [ payment.reference, value(payment) ] }

      private
        def value(payment)
          Payment.new(reference: payment.reference, state: payment.state, amount_cents: payment.amount_cents,
            currency: payment.currency, failure_reason: payment.failure_reason, voided_at: payment.voided_at)
        end
    end
  end
end
