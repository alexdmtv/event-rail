module Orders
  # Orders' public surface: checkout, the customer's actions on an order, and queries.
  # Every method is synchronous; what happens next arrives as Orders::Events.
  module Api
    CURRENCY = "EUR"
    STATES = Orders::Order::STATES

    # A snapshot of the customer, kept on the order. The shop has no customer module; the
    # caller supplies who is buying.
    Customer = Data.define(:id, :name, :email, :address)
    Line = Data.define(:sku, :name, :quantity, :unit_price_cents) do
      def total_cents = quantity * unit_price_cents
    end
    Order = Data.define(
      :id, :checkout_key, :reference, :state, :customer_id, :customer_name, :customer_email, :shipping_address,
      :total_cents, :currency, :lines, :correlation_id, :rejection_reason, :cancel_reason, :attention_reason, :tracking_code,
      :created_at, :placed_at, :rejected_at, :paid_at, :shipped_at, :delivered_at, :cancelled_at, :return_requested_at, :refunded_at
    ) do
      def cancellable? = state.in?(%w[ placed paid ])
      def returnable? = state == "delivered" && delivered_at > Orders::Order::RETURN_WINDOW.ago
    end

    class Error < StandardError; end
    class EmptyBasket < Error
      include Platform::InvalidArgument
    end
    class InvalidQuantity < Error
      include Platform::InvalidArgument
    end
    class UnknownProduct < Error
      include Platform::InvalidArgument
    end
    class ConflictingKey < Error
      include Platform::FailedPrecondition
    end
    class NotCancellable < Error
      include Platform::FailedPrecondition
    end
    class NotReturnable < Error
      include Platform::FailedPrecondition
    end

    class << self
      # Records the order, pending, and returns it; whether it is placed or rejected follows
      # in Orders::PlaceOrderJob. items: { "sku" => quantity }, each a whole number. Idempotent
      # on key: see Orders::Checkout.
      def checkout(customer:, items:, key:)
        value(Orders::Checkout.new(customer: customer, items: items, key: key).call)
      end

      def cancel(order_id, reason: "customer")
        value(Orders::Cancellation.new(Orders::Order.find(order_id), reason: reason).call)
      end

      def request_return(order_id)
        value(Orders::ReturnRequest.new(Orders::Order.find(order_id)).call)
      end

      # Cancels every order still placed and unpaid 30 minutes after checkout, and rejects
      # every order still pending then, staging its placement again to give back whatever it
      # took. Run every minute by Orders::ExpireAbandonedOrdersJob; returns how many orders it
      # ended.
      def expire_abandoned_orders
        rejected = Orders::Order.unplaced.find_each.count do |order|
          Orders::Flow.continue(order, step: "expire") do
            Orders::Order.transaction { Orders::PlaceOrderJob.stage_later(order.id) if order.reject!("not placed in time") }
          end
        end
        cancelled = Orders::Order.abandoned.find_each.count do |order|
          cancel(order.id, reason: "abandoned")
        rescue NotCancellable
          false # it moved on while the scan ran
        end
        rejected + cancelled
      end

      def order(id)
        order = Orders::Order.includes(:line_items).find_by(id: id)
        order && value(order)
      end

      # The order whose flow a correlation belongs to: every event of an order's flow carries
      # the correlation its checkout opened.
      def order_for_correlation(correlation_id)
        order = Orders::Order.includes(:line_items).find_by(correlation_id: correlation_id)
        order && value(order)
      end

      def recent(limit: 50) = Orders::Order.includes(:line_items).recent.limit(limit).map { |order| value(order) }

      def count_by_state = Orders::Order.group(:state).count

      private
        def value(order)
          Order.new(
            **order.slice(
              :id, :checkout_key, :reference, :state, :customer_id, :customer_name, :customer_email, :shipping_address, :total_cents,
              :currency, :correlation_id, :rejection_reason, :cancel_reason, :attention_reason, :tracking_code, :created_at, :placed_at,
              :rejected_at, :paid_at, :shipped_at, :delivered_at, :cancelled_at, :return_requested_at, :refunded_at
            ).symbolize_keys,
            lines: order.line_items.map { |line| Line.new(sku: line.sku, name: line.name, quantity: line.quantity, unit_price_cents: line.unit_price_cents) }
          )
        end
    end
  end
end
