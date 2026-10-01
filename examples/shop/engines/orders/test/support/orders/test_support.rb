module Orders
  # What other modules' tests need of Orders: a customer's carts and orders, driven through
  # Orders' own verbs, and the order read back as a record. It lives with Orders, so it may use
  # Orders' models; it is outside the load paths, so only tests can load it.
  module TestSupport
    Customer = Orders::Customer

    class << self
      def open_cart(customer:, items:) = Cart.open(customer:, items:)
      def place_order(cart_id) = Cart.find(cart_id).place_order
      def request_cancellation(order_id, reason: "customer") = Order.find(order_id).request_cancellation(reason:)
      def request_return(order_id) = Order.find(order_id).tap(&:request_return)
      def order(id) = Order.includes(:line_items, :returns).find_by(id: id)
    end
  end
end
