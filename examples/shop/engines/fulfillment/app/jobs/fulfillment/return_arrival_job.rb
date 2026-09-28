module Fulfillment
  # A returned parcel has arrived back at the warehouse. A stand-in carrier schedules it (see Carrier::Fake).
  class ReturnArrivalJob < ApplicationJob
    def perform(reference) = ParcelReturn.find_by_reference!(reference).receive
  end
end
