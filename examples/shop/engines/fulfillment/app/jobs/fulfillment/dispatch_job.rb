module Fulfillment
  class DispatchJob < ApplicationJob
    def perform(reference) = Shipment.find_by_reference!(reference).dispatch
  end
end
