module Orders
  # What other modules' tests need of Orders: a customer's carts and orders, driven through
  # Orders' own verbs, and the order read back as a record. It lives with Orders, so it may use
  # Orders' models; it is outside the load paths, so only tests can load it.
  module TestSupport
    # Who is buying, as a test describes them.
    Customer = Data.define(:id, :name, :email, :address)

    class << self
      # items: { "sku" => quantity }, for brevity; a cart takes them as a list.
      def open_cart(customer:, items:)
        Cart.open(customer_id: customer.id, customer_name: customer.name, customer_email: customer.email, shipping_address: customer.address,
          items: items.map { |sku, quantity| { sku: sku, quantity: quantity } })
      end

      def place_order(cart_id) = Cart.find(cart_id).place_order
      def request_cancellation(order_id, reason: "customer") = Order.find(order_id).request_cancellation(reason:)
      def request_return(order_id) = Order.find(order_id).tap(&:request_return)
      def order(id) = Order.includes(:line_items, :returns).find_by(id: id)
    end
  end
end
