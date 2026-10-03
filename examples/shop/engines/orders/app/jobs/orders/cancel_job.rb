module Orders
  class CancelJob < ApplicationJob
    def perform(order) = order.cancel
  end
end
