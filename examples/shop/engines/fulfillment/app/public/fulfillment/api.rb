module Fulfillment
  # Fulfillment's public surface. `request_shipment` and `request_return_pickup` accept a
  # request: they record it and return, the carrier works on its own schedule, and progress
  # arrives as Fulfillment::Events. `cancel_shipment` decides now, because its caller must know
  # whether the parcel has left. All three are safe to repeat per reference.
  module Api
    Recipient = Data.define(:name, :address)

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
    end
  end
end
