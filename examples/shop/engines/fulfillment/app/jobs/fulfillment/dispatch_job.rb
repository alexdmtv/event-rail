module Fulfillment
  # The carrier has collected the parcel. A stand-in carrier schedules it (see Carrier::Fake).
  class DispatchJob < ApplicationJob
    def perform(reference) = Shipment.find_by_reference!(reference).dispatch
  end
end
