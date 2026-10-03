module Fulfillment
  module TestSupport
    def self.shipment(reference) = Shipment.find_by(reference: reference)
    def self.parcel_return(reference) = ParcelReturn.find_by(reference: reference)
  end
end
