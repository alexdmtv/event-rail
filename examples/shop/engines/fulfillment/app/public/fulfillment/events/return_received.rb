module Fulfillment
  module Events
    class ReturnReceived < EventRail::Event
      event_type "fulfillment.return_received"
      version 1
      default_source "shop.fulfillment"
      identity_by :reference

      attribute :reference, :string

      validates :reference, presence: true
    end
  end
end
