module Fulfillment
  module TestSupport
    def self.shipment(reference) = Shipment.find_by(reference: reference)
    def self.parcel_return(reference) = ParcelReturn.find_by(reference: reference)

    # Plugs in the fake carrier, answering after the delay.
    def self.carrier_answering_after(delay) = Carrier.adapter = Carrier::Fake.new(delay:)

    # Back to the carrier the environment chose.
    def self.reset_carrier = Carrier.adapter = nil
  end
end
