module Orders
  # The carrier has the parcel. The reserved stock has physically left the warehouse.
  #
  # The announcement is made whenever the order has shipped, not only when this run moved
  # it: a redelivery of the same carrier event derives the same event identity, so
  # republishing is how a crash between the transition and the publication is recovered.
  class MarkShippedJob < ApplicationJob
    subscribes_to Fulfillment::Events::ShipmentDispatched

    def perform(event)
      order = Order.find_by(reference: event.reference) or return

      if order.transition!(from: "paid", to: "shipped", shipped_at: Time.current, tracking_code: event.tracking_code)
        Catalog::Api.ship(reservation_id: order.reference)
      end
      EventRail.publish(Events::OrderShipped.new(**order.event_attributes, tracking_code: order.tracking_code)) if order.shipped_or_later?
    end
  end
end
