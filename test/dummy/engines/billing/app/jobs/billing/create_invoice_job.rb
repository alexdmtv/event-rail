module Billing
  class CreateInvoiceJob < ApplicationJob
    subscribes_to Orders::OrderPlaced

    def perform(event)
      event
    end
  end
end
