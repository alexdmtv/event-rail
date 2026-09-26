module Fulfillment
  # The carrier has collected the parcel -- unless the shipment was cancelled first. Reports
  # the dispatch, and schedules the delivery, whenever the shipment is dispatched, not only
  # when this run dispatched it: a run retried after its transition committed must still
  # take the next step, and a repeated step republishes under the same identity.
  class DispatchJob < ApplicationJob
    def perform(reference)
      shipment = Shipment.find_by!(reference: reference)
      shipment.transition!(from: "requested", to: "dispatched", dispatched_at: Time.current, tracking_code: "TRK-#{SecureRandom.alphanumeric(8).upcase}")

      if shipment.dispatched_or_later?
        EventRail.publish(Events::ShipmentDispatched.new(reference: reference, tracking_code: shipment.tracking_code))
      end
      Carrier.current.carry(shipment) if shipment.dispatched?
    end
  end
end
