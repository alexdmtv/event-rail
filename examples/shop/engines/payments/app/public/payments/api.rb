module Payments
  # Payments' public surface.
  #
  # `authorize` decides now: confirming an order must know whether the card was declined.
  # `request_capture` and `request_release` accept a request: they record it on the payment
  # and return, a Payments job talks to the provider -- retrying while it does not answer --
  # and the outcome arrives as one of Payments::Events, once. The caller owns the decision to
  # move money; Payments owns how, and when it has happened.
  module Api
    class << self
      # Places a hold of the amount on the customer's card; raises Declined or Unavailable.
      # Safe to repeat for a reference.
      def authorize(reference:, amount_cents:, currency:) = Payments::Payment.authorize(reference:, amount_cents:, currency:).then { nil }

      # Takes the money the authorization holds, unless its release was asked for first.
      def request_capture(reference:) = Payments::Payment.request_capture(reference).then { nil }

      # Gives back whatever the payment holds: refunds it if it was captured, voids it if it was
      # not, after any capture still waiting for the provider's answer. For a caller undoing its
      # payment -- a cancelled order, a returned parcel -- without knowing whether a capture has
      # landed. Like every request here, it may name a reference with no payment, and then does
      # nothing.
      def request_release(reference:) = Payments::Payment.request_release(reference).then { nil }
    end
  end
end
