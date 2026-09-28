module Fulfillment
  # Fulfillment's public surface. `request_shipment` and `request_return_pickup` accept a
  # request: they record it and return, the carrier works on its own schedule, and progress
  # arrives as Fulfillment::Events. `cancel_shipment` decides now, because its caller must know
  # whether the parcel has left. All three are safe to repeat per reference.
  module Api
    Recipient = Data.define(:name, :address)
    Shipment = Data.define(:reference, :state, :tracking_code, :dispatched_at, :delivered_at)
    ParcelReturn = Data.define(:reference, :state, :received_at)

    class << self
      # items: { "sku" => quantity }. A shipment cancelled before this request arrives stays
      # cancelled.
      def request_shipment(reference:, recipient:, items:) = Fulfillment::Shipment.request(reference:, recipient:, items:).then { nil }

      # Stops a shipment the carrier has not collected. Fulfillment decides, because only
      # Fulfillment knows whether the parcel has left: the caller may not have heard yet.
      # Raises AlreadyDispatched once the carrier has the parcel.
      def cancel_shipment(reference:) = Fulfillment::Shipment.cancel(reference).then { nil }

      # Asks the carrier to bring a returned parcel back; ReturnReceived follows.
      def request_return_pickup(reference:) = Fulfillment::ParcelReturn.request_pickup(reference).then { nil }

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
