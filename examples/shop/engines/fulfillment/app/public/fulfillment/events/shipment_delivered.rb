module Fulfillment
  module Events
    class ShipmentDelivered < EventRail::Event
      event_type "fulfillment.shipment_delivered"
      version 1
      default_source "shop.fulfillment"
      identity_by :reference

      attribute :reference, :string

      validates :reference, presence: true
    end
  end
end
