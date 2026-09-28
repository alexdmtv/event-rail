module Orders
  # Orders' public surface: carts, placing an order, the customer's requests about an order,
  # and queries. Placing, cancelling and returning record the request and return; what happens
  # next arrives as Orders::Events.
  module Api
    CURRENCY = "EUR"
    STATUSES = %w[ placed confirmed paid shipped delivered returning refunded cancelled needs_attention ].freeze

    # A snapshot of the customer, kept on the cart and the order. The shop has no customer
    # module; the caller supplies who is buying.
    Customer = Data.define(:id, :name, :email, :address)
    Cart = Data.define(:id, :customer_id, :items, :order_id)
    Line = Data.define(:sku, :name, :quantity, :unit_price_cents) do
      def total_cents = quantity * unit_price_cents
    end
    # state is the order's lifecycle; status is what to show a person, derived from the state
    # and what has happened since.
    Order = Data.define(
      :id, :cart_id, :reference, :state, :status, :customer_id, :customer_name, :customer_email, :shipping_address,
      :total_cents, :currency, :lines, :correlation_id, :cancel_reason, :attention_reason, :tracking_code,
      :created_at, :confirmed_at, :paid_at, :shipped_at, :delivered_at, :cancellation_requested_at, :cancellation_refused_at,
      :cancelled_at, :return_state, :cancellable, :returnable
    ) do
      def cancellable? = cancellable
      def returnable? = returnable
    end

    class << self
      # Opens a cart with its items: { "sku" => quantity }, each a whole number above zero, as
      # an Integer or the digits a form submits. Raises InvalidQuantity or UnknownProduct.
      def open_cart(customer:, items:)
        quantities = items.to_h.to_h { |sku, quantity| [ sku.to_s, quantity.to_s == "0" ? nil : Orders::Quantity.parse(quantity) ] }.compact
        cart = Orders::Cart.open(customer: customer)
        quantities.each { |sku, quantity| cart.add(sku, quantity) }
        cart_value(cart)
      end

      def cart(id) = cart_value(Orders::Cart.find(id))

      # Places the cart's order and returns it, placed; whether it is confirmed or cancelled
      # follows. Placing a cart again returns the same order. Raises EmptyCart.
      def place_order(cart_id) = value(Orders::Cart.find(cart_id).place_order)

      # Records the request and returns; the order is cancelled, or the cancellation refused
      # because the parcel has left, a moment later. Raises NotCancellable once it has shipped.
      def request_cancellation(order_id, reason: "customer") = value(Orders::Order.find(order_id).request_cancellation(reason: reason))

      # Raises NotReturnable unless the order was delivered within its return window.
      def request_return(order_id) = Orders::Order.find(order_id).request_return.then { order(order_id) }

      def order(id)
        order = Orders::Order.includes(:line_items, :returns).find_by(id: id)
        order && value(order)
      end

      # The order whose flow a correlation belongs to: every event of an order's flow carries
      # the correlation its placement opened.
      def order_for_correlation(correlation_id)
        order = Orders::Order.includes(:line_items, :returns).find_by(correlation_id: correlation_id)
        order && value(order)
      end

      def recent(limit: 50) = Orders::Order.includes(:line_items, :returns).recent.limit(limit).map { |order| value(order) }

      # How many orders show each status.
      def status_counts = Orders::Order.includes(:returns).find_each.map(&:status).tally

      private
        def cart_value(cart)
          Cart.new(id: cart.id, customer_id: cart.customer_id, items: cart.items.to_h { |item| [ item.sku, item.quantity ] }, order_id: cart.order&.id)
        end

        def value(order)
          Order.new(
            **order.slice(
              :id, :cart_id, :reference, :state, :customer_id, :customer_name, :customer_email, :shipping_address, :total_cents,
              :currency, :correlation_id, :cancel_reason, :attention_reason, :tracking_code, :created_at, :confirmed_at, :paid_at,
              :shipped_at, :delivered_at, :cancellation_requested_at, :cancellation_refused_at, :cancelled_at
            ).symbolize_keys,
            status: order.status, return_state: order.returns.first&.state,
            cancellable: order.cancellable?, returnable: order.returnable?,
            lines: order.line_items.map { |line| Line.new(sku: line.sku, name: line.name, quantity: line.quantity, unit_price_cents: line.unit_price_cents) }
          )
        end
    end
  end
end
