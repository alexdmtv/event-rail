module Orders
  class CollectReturnJob < ApplicationJob
    def perform(order_return) = order_return.collect
  end
end
