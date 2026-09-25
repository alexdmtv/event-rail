module Orders
  # Orders' public surface: checkout, the customer's actions on an order, and queries.
  # Every method is synchronous; what happens next arrives as Orders::Events.
  module Api
    CURRENCY = "EUR"

    # A snapshot of the customer, kept on the order. The shop has no customer module; the
    # caller supplies who is buying.
    Customer = Data.define(:id, :name, :email, :address)
    Line = Data.define(:sku, :name, :quantity, :unit_price_cents) do
      def total_cents = quantity * unit_price_cents
    end
    Order = Data.define(
      :id, :reference, :state, :customer_id, :customer_name, :customer_email, :shipping_address,
      :total_cents, :currency, :lines, :correlation_id, :cancel_reason, :attention_reason, :tracking_code,
      :placed_at, :paid_at, :shipped_at, :delivered_at, :cancelled_at, :return_requested_at, :refunded_at
    ) do
      def cancellable? = state.in?(%w[ placed paid ])
      def returnable? = state == "delivered" && delivered_at > Orders::Order::RETURN_WINDOW.ago
    end

    class Error < StandardError; end
    class EmptyBasket < Error; end
    class UnknownProduct < Error; end
    class OutOfStock < Error; end
    class PaymentDeclined < Error; end
    class PaymentUnavailable < Error; end
    class ConflictingKey < Error; end
    class NotCancellable < Error; end
    class NotReturnable < Error; end

    class << self
      # items: { "sku" => quantity }. Idempotent on key: see Orders::Checkout.
      def checkout(customer:, items:, key:)
        value(Orders::Checkout.new(customer: customer, items: items, key: key).call)
      end

      def cancel(order_id, reason: "customer")
        value(Orders::Cancellation.new(Orders::Order.find(order_id), reason: reason).call)
      end

      def request_return(order_id)
        value(Orders::ReturnRequest.new(Orders::Order.find(order_id)).call)
      end

      def order(id)
        order = Orders::Order.includes(:line_items).find_by(id: id)
        order && value(order)
      end

      def recent(limit: 50) = Orders::Order.includes(:line_items).recent.limit(limit).map { |order| value(order) }

      def count_by_state = Orders::Order.group(:state).count

      private
        def value(order)
          Order.new(
            **order.slice(
              :id, :reference, :state, :customer_id, :customer_name, :customer_email, :shipping_address, :total_cents,
              :currency, :correlation_id, :cancel_reason, :attention_reason, :tracking_code, :placed_at, :paid_at,
              :shipped_at, :delivered_at, :cancelled_at, :return_requested_at, :refunded_at
            ).symbolize_keys,
            lines: order.line_items.map { |line| Line.new(sku: line.sku, name: line.name, quantity: line.quantity, unit_price_cents: line.unit_price_cents) }
          )
        end
    end
  end
end
