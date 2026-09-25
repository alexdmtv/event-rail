module Fulfillment
  # A returned parcel has arrived back at the warehouse.
  class ReturnArrivalJob < ApplicationJob
    def perform(reference)
      parcel_return = ParcelReturn.find_by!(reference: reference)
      ParcelReturn.where(id: parcel_return.id, state: "expected").update_all(state: "received", received_at: Time.current)

      EventRail.publish(Events::ReturnReceived.new(reference: reference)) if parcel_return.reload.received?
    end
  end
end
