module Fulfillment
  # A parcel on its way to a customer: requested, then dispatched by the carrier and delivered,
  # or cancelled before the carrier collected it. Every step is a conditional transition and
  # reports its state whenever the shipment is in it, not only when this run moved it: a step
  # retried after its transition committed still takes the next step, and republishes under the
  # same identity.
  class Shipment < ApplicationRecord
    def self.find_by_reference!(reference) = find_by!(reference: reference)

    # Records a shipment and hands it to the carrier. A shipment cancelled before this request
    # arrives stays cancelled.
    def self.request(reference:, recipient:, items:)
      shipment = create_or_find_by!(reference: reference) do |new_shipment|
        new_shipment.recipient_name = recipient.name
        new_shipment.address = recipient.address
        new_shipment.items = items
      end
      Carrier.current.pick_up(shipment) if shipment.requested?
    end

    # Stops a shipment the carrier has not collected. For a reference with no shipment, records
    # a cancelled one, so a request still on its way cannot revive it.
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

    # The carrier collected the parcel -- unless the shipment was cancelled first.
    def dispatch
      transition(from: "requested", to: "dispatched", dispatched_at: Time.current, tracking_code: "TRK-#{SecureRandom.alphanumeric(8).upcase}")

      EventRail.publish(Events::ShipmentDispatched.new(reference: reference, tracking_code: tracking_code)) if dispatched_or_later?
      Carrier.current.carry(self) if dispatched?
    end

    # The carrier handed the parcel over.
    def deliver
      transition(from: "dispatched", to: "delivered", delivered_at: Time.current)

      EventRail.publish(Events::ShipmentDelivered.new(reference: reference)) if delivered?
    end

    # Moves from `from` to `to` unless another process already did; true if this call did.
    def transition(from:, to:, **attributes)
      moved = self.class.where(id: id, state: from).update_all(attributes.merge(state: to, updated_at: Time.current))
      reload
      moved == 1
    end
  end
end
