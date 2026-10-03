module Payments
  # The request_* methods record the request and return; the outcome arrives as one of
  # Payments::Events. Both do nothing for a reference with no payment.
  module Api
    class << self
      # Places a hold on the card; raises Declined or Unavailable. Safe to repeat.
      def authorize(reference:, amount_cents:, currency:) = Payments::Payment.authorize(reference:, amount_cents:, currency:).then { nil }

      # Does nothing once a release has been asked for.
      def request_capture(reference:) = Payments::Payment.request_capture(reference).then { nil }

      # Refunds if captured, voids if not, after any capture still awaiting the provider's answer.
      def request_release(reference:) = Payments::Payment.request_release(reference).then { nil }
    end
  end
end
