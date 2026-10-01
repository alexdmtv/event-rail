module Payments
  # Makes a payment's pending capture. Started by the payment itself (Payment#request_capture).
  class CaptureJob < ApplicationJob
    def perform(payment, generation) = payment.carry_out(generation)
  end
end
