module Fulfillment
  # Fulfillment's public surface. Both commands are asynchronous: they record the request
  # and return, the carrier works on its own schedule, and progress arrives as
  # Fulfillment::Events. Both are idempotent per reference.
  module Api
    Recipient = Data.define(:name, :address)
    Shipment = Data.define(:reference, :state, :tracking_code, :dispatched_at, :delivered_at)
    ParcelReturn = Data.define(:reference, :state, :received_at)

    class << self
      # items: { "sku" => quantity }
      def request_shipment(reference:, recipient:, items:)
        shipment = Fulfillment::Shipment.create_or_find_by!(reference: reference) do |new_shipment|
          new_shipment.recipient_name = recipient.name
          new_shipment.address = recipient.address
          new_shipment.items = items
        end
        Carrier.current.pick_up(shipment) if shipment.state == "requested"
        nil
      end

      def expect_return(reference:)
        parcel_return = Fulfillment::ParcelReturn.create_or_find_by!(reference: reference)
        Carrier.current.bring_back(parcel_return) unless parcel_return.received?
        nil
      end

      def parcel_return(reference)
        parcel_return = Fulfillment::ParcelReturn.find_by(reference: reference)
        parcel_return && ParcelReturn.new(reference: parcel_return.reference, state: parcel_return.state, received_at: parcel_return.received_at)
      end

      def shipment(reference)
        shipment = Fulfillment::Shipment.find_by(reference: reference)
        shipment && shipment_value(shipment)
      end

      # The shipments for many references at once, by reference.
      def shipments(references) = Fulfillment::Shipment.where(reference: references).to_h { |shipment| [ shipment.reference, shipment_value(shipment) ] }

      private
        def shipment_value(shipment)
          Shipment.new(reference: shipment.reference, state: shipment.state, tracking_code: shipment.tracking_code,
            dispatched_at: shipment.dispatched_at, delivered_at: shipment.delivered_at)
        end
    end
  end
end
