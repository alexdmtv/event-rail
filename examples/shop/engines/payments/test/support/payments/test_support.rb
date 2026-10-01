module Payments
  # What other modules' tests need of Payments: the payment for a reference, or nil. It lives
  # with Payments, so it may use Payments' models; it is outside the load paths, so only tests
  # can load it.
  module TestSupport
    def self.payment(reference) = Payment.find_by(reference: reference)
  end
end
