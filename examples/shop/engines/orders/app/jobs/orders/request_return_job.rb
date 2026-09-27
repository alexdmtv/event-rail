module Orders
  # Tells Fulfillment to expect a returned parcel. Staged with the order's move to awaiting
  # return (Orders::ReturnRequest), so the carrier hears of every return the customer was
  # told was accepted.
  class RequestReturnJob < ApplicationJob
    def perform(order_id)
      order = Order.find(order_id)
      Fulfillment::Api.expect_return(reference: order.reference) if order.awaiting_return?
    end
  end
end
