module Orders
  # What other modules' tests and the host's may use of Orders: the customer's actions, and what
  # an order looks like from outside, as values, never records, so Orders can change inside without
  # breaking anyone else's tests. Readers return symbols.
  module TestSupport
    Customer = Data.define(:id, :name, :email, :address)
    CUSTOMER = Customer.new(id: "cus_ada", name: "Ada Lovelace", email: "ada@example.com", address: "12 St James's Square, London")
    ITEMS = { "MUG" => 2, "TEA" => 1 }.freeze

    STATES = { "placed" => :placed, "confirmed" => :confirmed, "cancelled" => :cancelled }.freeze
    STATUSES = STATES.merge("paid" => :paid, "shipped" => :shipped, "delivered" => :delivered, "returning" => :returning,
      "refunded" => :refunded, "needs_attention" => :needs_attention).freeze
    RETURNS = { "requested" => :requested, "received" => :received, "refunded" => :refunded, "refund_failed" => :refund_failed }.freeze

    # An order as anyone outside Orders sees it. status is the one a customer sees: it follows the
    # order through payment, shipping and any return; return_status is nil until a return is asked for.
    Snapshot = Data.define(:id, :reference, :state, :status, :cancel_reason, :refund_failure_reason, :cancellation_refused, :return_status) do
      def cancellation_refused? = cancellation_refused
    end

    class << self
      # items: { "sku" => quantity }. Answers the cart's ID.
      def open_cart(customer:, items:)
        Cart.open(customer_id: customer.id, customer_name: customer.name, customer_email: customer.email, shipping_address: customer.address,
          items: items.map { |sku, quantity| { sku: sku, quantity: quantity } }).id
      end

      def place_order(cart_id) = snapshot(as_request { Cart.find(cart_id).place_order }.id)
      def request_cancellation(order_id, reason: "customer") = as_request { Order.find(order_id).request_cancellation(reason:) }.then { snapshot(order_id) }
      def request_return(order_id) = as_request { Order.find(order_id).request_return }.then { snapshot(order_id) }
      def order(id) = (snapshot(id) if Order.exists?(id))

      # The customer fills a cart and places it; the order's confirmation is queued, not run.
      def checkout(items: ITEMS, customer: CUSTOMER) = place_order(open_cart(customer:, items:))

      # As checkout, and the confirmation runs, its retries too, without waiting for them: the order
      # ends confirmed, with its stock held, its card authorized and the capture queued, or cancelled
      # if either failed for good.
      def place_and_confirm(**checkout)
        placed = checkout(**checkout)
        Platform::TestSupport::Worker.perform_queued(ConfirmJob, CancelJob)
        snapshot(placed.id)
      end

      private
        def snapshot(id)
          order = Order.includes(:return).find(id)
          Snapshot.new(id: order.id, reference: order.reference, state: STATES.fetch(order.state), status: STATUSES.fetch(order.status),
            cancel_reason: order.cancel_reason, refund_failure_reason: order.refund_failure_reason, cancellation_refused: order.cancellation_refused_at?,
            return_status: order.return&.state&.then { RETURNS.fetch(_1) })
        end

        # A flow of its own, as each web request is (Platform::ApplicationController).
        def as_request(&) = EventRail.with_context(message_id: "request-#{SecureRandom.uuid}", &)
    end
  end
end

require_relative "steps"
