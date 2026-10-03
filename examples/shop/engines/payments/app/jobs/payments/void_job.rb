module Payments
  class VoidJob < ApplicationJob
    def perform(payment, generation) = payment.carry_out(generation)
  end
end
