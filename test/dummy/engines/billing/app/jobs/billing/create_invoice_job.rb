module Billing
  class CreateInvoiceJob < ApplicationJob
    def perform(order_id)
      order_id
    end
  end
end
