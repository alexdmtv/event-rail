module Orders
  class Order
    # Translates the order into the events Orders publishes: every field other modules see is
    # chosen here, named one by one. The traits decide when an event is staged.
    class Announcements
      def initialize(order)
        @order = order
      end

      def placed = Events::OrderPlaced.new(**customer, total:, line_items:)
      def cancelled = Events::OrderCancelled.new(**customer, reason: @order.cancel_reason)
      def shipped = Events::OrderShipped.new(**customer, tracking_code: @order.tracking_code)
      def delivered = Events::OrderDelivered.new(**customer, total:)
      def refunded = Events::OrderRefunded.new(**customer, total:)

      private
        def customer
          { order_id: @order.id.to_s, customer_id: @order.customer_id, customer_name: @order.customer_name, customer_email: @order.customer_email }
        end

        def total = { amount_cents: @order.total_cents, currency: @order.currency }

        def line_items
          @order.line_items.map do |line|
            { sku: line.sku, name: line.name, quantity: line.quantity, unit_price_cents: line.unit_price_cents }
          end
        end
    end
  end
end
