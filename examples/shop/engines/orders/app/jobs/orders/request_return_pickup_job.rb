module Orders
  class RequestReturnPickupJob < ApplicationJob
    def perform(order_return) = order_return.request_pickup
  end
end
