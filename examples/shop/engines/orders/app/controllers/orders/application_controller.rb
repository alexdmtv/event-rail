module Orders
  # Orders' HTTP API, for outside clients. Its JSON is written out here field by field: it is a
  # contract of its own, separate from the records, so a change to a record cannot change it by
  # accident.
  class ApplicationController < Platform::ApplicationController
    private
      def render_order(order, status: :ok)
        render status: status, json: {
          id: order.id,
          status: order.status,
          total: { cents: order.total_cents, currency: order.currency },
          lines: order.line_items.map { |line| { sku: line.sku, name: line.name, quantity: line.quantity, unit_price_cents: line.unit_price_cents } },
          tracking_code: order.tracking_code,
          cancel_reason: order.cancel_reason,
          attention_reason: order.attention_reason,
          placed_at: order.created_at,
          confirmed_at: order.confirmed_at,
          paid_at: order.paid_at,
          shipped_at: order.shipped_at,
          delivered_at: order.delivered_at,
          cancellation_requested_at: order.cancellation_requested_at,
          cancellation_refused_at: order.cancellation_refused_at,
          cancelled_at: order.cancelled_at,
          cancellable: order.cancellable?,
          returnable: order.returnable?
        }
      end
  end
end
