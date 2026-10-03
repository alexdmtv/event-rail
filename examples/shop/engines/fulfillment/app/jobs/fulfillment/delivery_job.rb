module Fulfillment
  class DeliveryJob < ApplicationJob
    def perform(reference) = Shipment.find_by_reference!(reference).deliver
  end
end
