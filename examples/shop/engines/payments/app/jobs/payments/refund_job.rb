module Payments
  class RefundJob < ApplicationJob
    def perform(payment, generation) = payment.carry_out(generation)
  end
end
