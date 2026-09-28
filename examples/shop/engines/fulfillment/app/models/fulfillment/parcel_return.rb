module Fulfillment
  # A parcel the customer is sending back: expected, then received at the warehouse.
  class ParcelReturn < ApplicationRecord
    self.table_name = "fulfillment_returns"

    def self.find_by_reference!(reference) = find_by!(reference: reference)

    # Asks the carrier to bring the parcel back. Repeating it asks once.
    def self.request_pickup(reference)
      parcel_return = create_or_find_by!(reference: reference)
      Carrier.current.bring_back(parcel_return) unless parcel_return.received?
    end

    def received? = state == "received"

    # The parcel is back at the warehouse.
    def receive
      self.class.where(id: id, state: "expected").update_all(state: "received", received_at: Time.current)
      reload

      EventRail.publish(Events::ReturnReceived.new(reference: reference)) if received?
    end
  end
end
