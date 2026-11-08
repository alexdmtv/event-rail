module Orders
  # What other modules' tests and the host's may use of Orders: the customer's actions, and what
  # an order looks like from outside, as values, never records, so Orders can change inside without
  # breaking anyone else's tests.
  module TestSupport
    Customer = Data.define(:id, :name, :email, :address)
    CUSTOMER = Customer.new(id: "cus_ada", name: "Ada Lovelace", email: "ada@example.com", address: "12 St James's Square, London")
    ITEMS = { "MUG" => 2, "TEA" => 1 }.freeze

    # An order as anyone outside Orders sees it. status is the one a customer sees: it follows the
    # order through payment, shipping and any return.
    Snapshot = Data.define(:id, :reference, :state, :status, :cancel_reason, :refund_failure_reason, :cancellation_refused, :return_status)

    class << self
      # items: { "sku" => quantity }
      def open_cart(customer:, items:)
        Cart.open(customer_id: customer.id, customer_name: customer.name, customer_email: customer.email, shipping_address: customer.address,
          items: items.map { |sku, quantity| { sku: sku, quantity: quantity } })
      end

      def place_order(cart_id) = as_request { Cart.find(cart_id).place_order }
      def request_cancellation(order_id, reason: "customer") = as_request { Order.find(order_id).request_cancellation(reason:) }
      def request_return(order_id) = as_request { Order.find(order_id).tap(&:request_return) }
      def order(id) = Order.includes(:line_items, :return).find_by(id: id)

      # The customer fills a cart and places it; the order's confirmation is queued, not run.
      def checkout(items: ITEMS, customer: CUSTOMER) = snapshot(place_order(open_cart(customer:, items:).id).id)

      # As checkout, and the confirmation runs: the order ends confirmed, with its stock held and its
      # card authorized and the capture queued, or cancelled if either failed.
      def place_and_confirm(**checkout)
        placed = checkout(**checkout)
        Platform::TestSupport::Worker.perform_queued(ConfirmJob, CancelJob)
        snapshot(placed.id)
      end

      private
        def snapshot(id)
          order = Order.includes(:return).find(id)
          Snapshot.new(id: order.id, reference: order.reference, state: order.state, status: order.status, cancel_reason: order.cancel_reason,
            refund_failure_reason: order.refund_failure_reason, cancellation_refused: order.cancellation_refused_at?, return_status: order.return&.state)
        end

        # A flow of its own, as each web request is (Platform::ApplicationController).
        def as_request(&) = EventRail.with_context(message_id: "request-#{SecureRandom.uuid}", &)
    end
  end
end
