module Fulfillment
  # The carrier has handed the parcel over. A stand-in carrier schedules it (see Carrier::Fake).
  class DeliveryJob < ApplicationJob
    def perform(reference) = Shipment.find_by_reference!(reference).deliver
  end
end
