module Fulfillment
  class ReturnArrivalJob < ApplicationJob
    def perform(reference) = ParcelReturn.find_by_reference!(reference).receive
  end
end
