module Orders
  # The carrier has the parcel.
  class MarkShippedJob < ApplicationJob
    subscribes_to Fulfillment::Events::ShipmentDispatched

    def perform(event) = Order.find_by(reference: event.reference)&.mark_shipped(tracking_code: event.tracking_code)
  end
end
