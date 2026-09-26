module Orders
  # The customer has the parcel.
  class MarkDeliveredJob < ApplicationJob
    subscribes_to Fulfillment::Events::ShipmentDelivered

    def perform(event)
      order = Order.find_by(reference: event.reference) or return
      raise NotYetShipped, "order #{order.id} was delivered before its dispatch was recorded" if order.paid?

      order.transition!(from: "shipped", to: "delivered", delivered_at: Time.current)
      EventRail.publish(Events::OrderDelivered.new(**order.event_attributes, total: order.total)) if order.delivered_or_later?
    end
  end
end
