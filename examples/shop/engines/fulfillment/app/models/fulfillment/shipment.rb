module Fulfillment
  class Shipment < ApplicationRecord
    def self.find_by_reference!(reference) = find_by!(reference: reference)

    # A shipment cancelled before this request arrives stays cancelled.
    def self.request(reference:, recipient:, items:)
      shipment = create_or_find_by!(reference: reference) do |new_shipment|
        new_shipment.recipient_name = recipient.name
        new_shipment.address = recipient.address
        new_shipment.items = items
      end
      Carrier.current.pick_up(shipment) if shipment.requested?
    end

    # Raises AlreadyDispatched once the carrier has it. With no shipment yet, records a
    # cancelled one so a request still on its way cannot revive it.
    def self.cancel(reference)
      shipment = create_or_find_by!(reference: reference) do |new_shipment|
        new_shipment.state = "cancelled"
        new_shipment.cancelled_at = Time.current
      end
      shipment.transition(from: "requested", to: "cancelled", cancelled_at: Time.current)
      raise AlreadyDispatched, "shipment #{reference} has been dispatched" if shipment.dispatched_or_later?
    end

    def requested? = state == "requested"
    def dispatched? = state == "dispatched"
    def dispatched_or_later? = state.in?(%w[ dispatched delivered ])
    def delivered? = state == "delivered"

    # Hands on to the carrier whenever dispatched, not only after this call's move, so a retry
    # after the move committed still does.
    def dispatch
      transition(from: "requested", to: "dispatched", dispatched_at: Time.current, tracking_code: "TRK-#{SecureRandom.alphanumeric(8).upcase}") do
        EventRail.stage(Events::ShipmentDispatched.new(reference: reference, tracking_code: tracking_code))
      end
      Carrier.current.carry(self) if dispatched?
    end

    def deliver
      transition(from: "dispatched", to: "delivered", delivered_at: Time.current) do
        EventRail.stage(Events::ShipmentDelivered.new(reference: reference))
      end
    end

    # True only if this call made the move; the block commits with it and runs only then.
    def transition(from:, to:, **attributes, &) = update_if({ state: from }, state: to, **attributes, &)
  end
end
