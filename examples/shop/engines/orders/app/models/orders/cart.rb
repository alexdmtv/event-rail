module Orders
  # A customer's list of intended purchases, until it is ordered. Placing it creates the
  # order, which holds the cart's ID under a unique index: a cart gives at most one order, so
  # placing it again -- a double click, a retry after a timeout -- returns that order.
  class Cart < ApplicationRecord
    # A cart's items arrive with it and are validated with it, each error numbered by the item's
    # position in the request (items[1].quantity).
    has_many :items, class_name: "CartItem", inverse_of: :cart, dependent: :delete_all, index_errors: true
    accepts_nested_attributes_for :items
    has_one :order

    validates :customer_id, :customer_name, :customer_email, :shipping_address, presence: true
    validates :customer_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true

    # Opens a cart with the customer's details and the items, [{ sku:, quantity: }], validated
    # together so the client hears every problem at once: Platform::InvalidInput lists each one,
    # named by the request's own fields (customer_email, items[1].quantity). The cart and its
    # items commit together.
    def self.open(attributes)
      attributes = attributes.to_h.symbolize_keys
      create!(**attributes.except(:items), items_attributes: Array(attributes[:items]))
    rescue ActiveRecord::RecordInvalid => invalid
      raise Platform::InvalidInput.from(invalid.record.errors)
    end

    # The catalog's products for the cart's items, by SKU, asked of Catalog once for every item's
    # validation.
    def catalog_products = @catalog_products ||= Catalog::Api.products(items.filter_map(&:sku)).index_by(&:sku)

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
            total_cents: quote.total_cents, currency: Order::CURRENCY, correlation_id: EventRail::Current.correlation_id
          )
          quote.lines.each do |line|
            order.line_items.create!(sku: line.sku, name: line.name, quantity: line.quantity, unit_price_cents: line.unit_price_cents)
          end
          order.announce_placement
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
