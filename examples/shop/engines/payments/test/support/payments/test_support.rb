module Payments
  module TestSupport
    def self.payment(reference) = Payment.find_by(reference: reference)
  end
end
