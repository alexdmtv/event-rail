module Fulfillment
  # Every method is safe to repeat per reference; progress arrives as Fulfillment::Events.
  module Api
    Recipient = Data.define(:name, :address)

    class << self
      # items: { "sku" => quantity }. A shipment cancelled before this request arrives stays
      # cancelled.
      def request_shipment(reference:, recipient:, items:) = Fulfillment::Shipment.request(reference:, recipient:, items:).then { nil }

      # Raises AlreadyDispatched once the carrier has the parcel.
      def cancel_shipment(reference:) = Fulfillment::Shipment.cancel(reference).then { nil }

      # ReturnReceived follows.
      def request_return_pickup(reference:) = Fulfillment::ParcelReturn.request_pickup(reference).then { nil }
    end
  end
end
