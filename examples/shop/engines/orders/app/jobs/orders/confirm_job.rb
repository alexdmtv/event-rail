module Orders
  # Confirms an order placed from its cart; staged when it was placed.
  class ConfirmJob < ApplicationJob
    def perform(order) = order.confirm
  end
end
