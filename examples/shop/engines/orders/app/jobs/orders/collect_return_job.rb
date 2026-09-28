module Orders
  # Asks the carrier to collect a returned parcel; staged with the return.
  class CollectReturnJob < ApplicationJob
    def perform(order_return) = order_return.collect
  end
end
