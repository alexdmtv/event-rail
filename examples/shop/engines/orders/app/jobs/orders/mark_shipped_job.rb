module Orders
  class MarkShippedJob < ApplicationJob
    subscribes_to Fulfillment::Events::ShipmentDispatched

    def perform(event) = Order.for_reference(event.reference)&.mark_shipped(tracking_code: event.tracking_code)
  end
end
