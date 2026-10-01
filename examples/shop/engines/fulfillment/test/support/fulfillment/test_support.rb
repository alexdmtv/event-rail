module Fulfillment
  # What other modules' tests need of Fulfillment: the shipment and the parcel return for a
  # reference, or nil. It lives with Fulfillment, so it may use Fulfillment's models; it is
  # outside the load paths, so only tests can load it.
  module TestSupport
    def self.shipment(reference) = Shipment.find_by(reference: reference)
    def self.parcel_return(reference) = ParcelReturn.find_by(reference: reference)
  end
end
