module Payments
  class CaptureJob < ApplicationJob
    def perform(payment, generation) = payment.carry_out(generation)
  end
end
