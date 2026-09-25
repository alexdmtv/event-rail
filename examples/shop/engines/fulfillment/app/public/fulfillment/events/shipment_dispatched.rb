module Fulfillment
  module Events
    class ShipmentDispatched < EventRail::Event
      event_type "fulfillment.shipment_dispatched"
      version 1
      default_source "shop.fulfillment"
      identity_by :reference

      attribute :reference, :string
      attribute :tracking_code, :string

      validates :reference, presence: true
    end
  end
end
