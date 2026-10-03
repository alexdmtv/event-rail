module Orders
  module TestSupport
    Customer = Data.define(:id, :name, :email, :address)

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

      private
        # A flow of its own, as each web request is (Platform::ApplicationController).
        def as_request(&) = EventRail.with_context(message_id: "request-#{SecureRandom.uuid}", &)
    end
  end
end
