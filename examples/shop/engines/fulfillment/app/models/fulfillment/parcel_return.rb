module Fulfillment
  class ParcelReturn < ApplicationRecord
    self.table_name = "fulfillment_returns"

    # Its bang methods (received!) skip the return's transitions; never call them.
    enum :state, %w[ expected received ].index_by(&:itself), validate: true

    def self.find_by_reference!(reference) = find_by!(reference: reference)

    def self.request_pickup(reference)
      parcel_return = create_or_find_by!(reference: reference)
      Carrier.current.bring_back(parcel_return) unless parcel_return.received?
    end

    def receive
      update_if({ state: "expected" }, state: "received", received_at: Time.current) do
        EventRail.stage(Events::ReturnReceived.new(reference: reference))
      end
    end
  end
end
