module Payments
  # Payments' public surface.
  #
  # `authorize` decides now: confirming an order must know whether the card was declined.
  # `request_capture` and `request_release` accept a request: they record it on the payment
  # and return, a Payments job talks to the provider -- retrying while it does not answer --
  # and the outcome arrives as one of Payments::Events, once. The caller owns the decision to
  # move money; Payments owns how, and when it has happened.
  module Api
    # pending_operation is the provider call waiting to be made or answered, sent at
    # operation_sent_at: a payment stuck there needs its failed job replayed.
    Payment = Data.define(:reference, :state, :amount_cents, :currency, :failure_reason, :voided_at,
      :pending_operation, :operation_sent_at, :release_requested_at)

    class << self
      # Places a hold of the amount on the customer's card; raises Declined or Unavailable.
      # Safe to repeat for a reference.
      def authorize(reference:, amount_cents:, currency:) = value(Payments::Payment.authorize(reference:, amount_cents:, currency:))

      # Takes the money the authorization holds, unless its release was asked for first.
      def request_capture(reference:) = Payments::Payment.request_capture(reference).then { nil }

      # Gives back whatever the payment holds: refunds it if it was captured, voids it if it was
      # not, after any capture still waiting for the provider's answer. For a caller undoing its
      # payment -- a cancelled order, a returned parcel -- without knowing whether a capture has
      # landed. Like every request here, it may name a reference with no payment, and then does
      # nothing.
      def request_release(reference:) = Payments::Payment.request_release(reference).then { nil }

      def payment(reference)
        payment = Payments::Payment.find_by(reference: reference)
        payment && value(payment)
      end

      # The payments for many references at once, by reference.
      def payments(references) = Payments::Payment.where(reference: references).to_h { |payment| [ payment.reference, value(payment) ] }

      private
        def value(payment)
          Payment.new(**payment.slice(:reference, :state, :amount_cents, :currency, :failure_reason, :voided_at,
            :pending_operation, :operation_sent_at, :release_requested_at).symbolize_keys)
        end
    end
  end
end
