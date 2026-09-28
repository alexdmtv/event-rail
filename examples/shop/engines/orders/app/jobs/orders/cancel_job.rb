module Orders
  # Carries out a requested cancellation; staged with the request.
  class CancelJob < ApplicationJob
    def perform(order) = order.cancel
  end
end
