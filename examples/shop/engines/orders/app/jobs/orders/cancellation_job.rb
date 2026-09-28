module Orders
  # The rest of a cancellation, after Orders::Cancellation decided it: gives back the stock
  # and the payment, and announces the cancellation.
  #
  # Payments decides between voiding and refunding, from its own state, when it runs: an
  # order still `placed` may have a capture that landed before Orders heard of it. The
  # announcement is unconditional, so a run retried after publishing publishes again, under
  # the same identity: OrderCancelled is identified by its order.
  class CancellationJob < ApplicationJob
    def perform(order_id)
      order = Order.find(order_id)
      return unless order.cancelled?

      Catalog::Api.release(reservation_id: order.reference)
      Payments::Api.request_release(reference: order.reference)
      EventRail.publish(Events::OrderCancelled.new(**order.event_attributes, reason: order.cancel_reason))
      order.update_columns(cancellation_announced_at: Time.current) unless order.cancellation_announced_at?
    end
  end
end
