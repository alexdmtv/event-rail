module Orders
  # The customer has the parcel.
  class MarkDeliveredJob < ApplicationJob
    subscribes_to Fulfillment::Events::ShipmentDelivered

    def perform(event) = Order.for_reference(event.reference)&.mark_delivered
  end
end
