module Orders
  class ConfirmJob < ApplicationJob
    def perform(order) = order.confirm
  end
end
