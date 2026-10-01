module Payments
  # Returns captured money to the customer. Started by the payment for a release
  # (Payment#request_release).
  class RefundJob < ApplicationJob
    def perform(payment, generation) = payment.carry_out(generation)
  end
end
