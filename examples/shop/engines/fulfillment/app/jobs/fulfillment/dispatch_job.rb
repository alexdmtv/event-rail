module Fulfillment
  # The carrier has collected the parcel. Reports the dispatch whether or not this run made
  # it, so a repeated step republishes under the same identity instead of losing the event.
  class DispatchJob < ApplicationJob
    def perform(reference)
      shipment = Shipment.find_by!(reference: reference)
      moved = shipment.transition!(from: "requested", to: "dispatched", dispatched_at: Time.current, tracking_code: "TRK-#{SecureRandom.alphanumeric(8).upcase}")

      if shipment.dispatched_or_later?
        EventRail.publish(Events::ShipmentDispatched.new(reference: reference, tracking_code: shipment.tracking_code))
      end
      Carrier.current.carry(shipment) if moved
    end
  end
end
