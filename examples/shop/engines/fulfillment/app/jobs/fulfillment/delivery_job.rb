module Fulfillment
  # The carrier has handed the parcel over.
  class DeliveryJob < ApplicationJob
    def perform(reference)
      shipment = Shipment.find_by!(reference: reference)
      shipment.transition!(from: "dispatched", to: "delivered", delivered_at: Time.current)

      EventRail.publish(Events::ShipmentDelivered.new(reference: reference)) if shipment.delivered?
    end
  end
end
