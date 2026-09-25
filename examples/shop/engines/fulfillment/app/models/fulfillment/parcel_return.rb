module Fulfillment
  # A parcel the customer is sending back.
  class ParcelReturn < ApplicationRecord
    self.table_name = "fulfillment_returns"

    def received? = state == "received"
  end
end
