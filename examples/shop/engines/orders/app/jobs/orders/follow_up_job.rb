module Orders
  # Everything after checkout's decision: announcing the order, then asking Payments to
  # capture it. Enqueued under an ID derived from the order, so a resumed checkout enqueues
  # the same job again and its announcement carries the same event ID -- subscribers see a
  # repetition, not a second order.
  #
  # The announcement is unconditional: a run that crashed after publishing is retried and
  # publishes again under the same identity, rather than skipping a step it cannot tell it
  # finished.
  class FollowUpJob < ApplicationJob
    def perform(order_id)
      order = Order.find(order_id)

      EventRail.publish(Events::OrderPlaced.new(
        **order.event_attributes, total: order.total,
        line_items: order.line_items.map do |line|
          { "sku" => line.sku, "name" => line.name, "quantity" => line.quantity, "unit_price_cents" => line.unit_price_cents }
        end
      ))
      Payments::Api.capture(reference: order.reference) if order.placed?
    end
  end
end
