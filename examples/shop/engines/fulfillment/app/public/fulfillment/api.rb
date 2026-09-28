module Fulfillment
  # Fulfillment's public surface. `request_shipment` and `expect_return` are asynchronous:
  # they record the request and return, the carrier works on its own schedule, and progress
  # arrives as Fulfillment::Events. `cancel_shipment` is synchronous, because its caller must
  # know now whether the parcel has left. All three are idempotent per reference.
  module Api
    Recipient = Data.define(:name, :address)
    Shipment = Data.define(:reference, :state, :tracking_code, :dispatched_at, :delivered_at)
    ParcelReturn = Data.define(:reference, :state, :received_at)

    # The carrier already has the parcel.
    class AlreadyDispatched < StandardError
      include Platform::FailedPrecondition
    end

    class << self
      # items: { "sku" => quantity }. A shipment cancelled before this request arrives stays
      # cancelled.
      def request_shipment(reference:, recipient:, items:)
        shipment = Fulfillment::Shipment.create_or_find_by!(reference: reference) do |new_shipment|
          new_shipment.recipient_name = recipient.name
          new_shipment.address = recipient.address
          new_shipment.items = items
        end
        Carrier.current.pick_up(shipment) if shipment.requested?
        nil
      end

      # Stops a shipment the carrier has not collected. Fulfillment decides, because only
      # Fulfillment knows whether the parcel has left: the caller may not have heard yet. For
      # a reference with no shipment, it records a cancelled one, so a request still on its
      # way cannot revive it. Raises AlreadyDispatched once the carrier has the parcel.
      def cancel_shipment(reference:)
        shipment = Fulfillment::Shipment.create_or_find_by!(reference: reference) do |new_shipment|
          new_shipment.state = "cancelled"
          new_shipment.cancelled_at = Time.current
        end
        shipment.transition!(from: "requested", to: "cancelled", cancelled_at: Time.current)
        raise AlreadyDispatched, "shipment #{reference} has been dispatched" if shipment.dispatched_or_later?

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
