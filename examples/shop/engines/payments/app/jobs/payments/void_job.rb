module Payments
  # Releases an authorization that will never be captured -- one never captured, or one whose
  # capture was refused. Started by the payment for a release (Payment#request_release).
  class VoidJob < ApplicationJob
    def perform(payment, generation) = payment.carry_out(generation)
  end
end
