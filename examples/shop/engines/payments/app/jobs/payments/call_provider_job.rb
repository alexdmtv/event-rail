module Payments
  class CallProviderJob < ApplicationJob
    def perform(call) = call.payment.carry_out(call.id)
  end
end
