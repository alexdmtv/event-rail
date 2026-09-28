module Orders
  # A customer's list of intended purchases, until it is ordered. Placing it creates the
  # order, which holds the cart's ID under a unique index: a cart gives at most one order, so
  # placing it again -- a double click, a retry after a timeout -- returns that order.
  class Cart < ApplicationRecord
    has_many :items, class_name: "CartItem", dependent: :delete_all
    has_one :order

    # customer: an Api::Customer snapshot, kept on the order it becomes.
    def self.open(customer:)
      create!(customer_id: customer.id, customer_name: customer.name, customer_email: customer.email, shipping_address: customer.address)
    end

    def ordered? = order.present?

    # Adds a product, or more of one already in the cart. The product must exist; its price is
    # read when the order is placed, not now.
    def add(sku, quantity)
      raise CartAlreadyOrdered, "cart #{id} was already ordered" if ordered?

      Catalog::Api.product(sku)
      item = items.find_or_initialize_by(sku: sku)
      item.update!(quantity: (item.quantity || 0) + quantity.count)
    rescue Catalog::UnknownProduct => unknown
      raise UnknownProduct, unknown.message
    end

    # Places the order: prices the items as they are now, records the order and its lines, and
    # stages its confirmation, in one transaction. The flow of the order starts here, and a
    # repeat continues it.
    def place_order
      order || EventRail.with_context(message_id: "cart-#{id}") { record_order }
    end

    private
      def record_order
        raise EmptyCart, "a cart needs at least one item to be ordered" if items.empty?

        quote = Catalog::Api.quote(items.to_h { |item| [ item.sku, item.quantity ] })
        Order.transaction do
          order = Order.create!(
            cart: self,
            state: "placed", customer_id:, customer_name:, customer_email:, shipping_address:,
            total_cents: quote.total_cents, currency: Api::CURRENCY, correlation_id: EventRail::Current.correlation_id
          )
          quote.lines.each do |line|
            order.line_items.create!(sku: line.sku, name: line.name, quantity: line.quantity, unit_price_cents: line.unit_price_cents)
          end
          order.confirm_later
          order
        end
      rescue ActiveRecord::RecordNotUnique
        reload.order or raise # another submission placed it first
      rescue Catalog::UnknownProduct => unknown
        raise UnknownProduct, unknown.message
      end
  end
end
