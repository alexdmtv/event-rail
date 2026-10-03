module Orders
  class Cart < ApplicationRecord
    has_many :items, class_name: "CartItem", inverse_of: :cart, dependent: :delete_all, index_errors: true
    accepts_nested_attributes_for :items
    has_one :order

    validates :customer_id, :customer_name, :customer_email, :shipping_address, presence: true
    validates :customer_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true

    # Takes the customer's details and items: [{ sku:, quantity: }]. Raises Platform::InvalidInput
    # listing every problem, named by the request's fields (customer_email, items[1].quantity).
    def self.open(attributes)
      attributes = attributes.to_h.symbolize_keys
      create!(**attributes.except(:items), items_attributes: Array(attributes[:items]))
    rescue ActiveRecord::RecordInvalid => invalid
      raise Platform::InvalidInput.from(invalid.record.errors)
    end

    def catalog_products = @catalog_products ||= Catalog::Api.products(items.filter_map(&:sku)).index_by(&:sku)

    # Safe to repeat: the order holds the cart's ID under a unique index, so placing the cart
    # again returns that order. Raises EmptyCart or UnknownProduct.
    def place_order
      order || record_order
    end

    private
      def record_order
        raise EmptyCart, "a cart needs at least one item to be ordered" if items.empty?

        quote = Catalog::Api.quote(items.to_h { |item| [ item.sku, item.quantity ] })
        Order.transaction do
          order = Order.create!(
            cart: self,
            state: "placed", customer_id:, customer_name:, customer_email:, shipping_address:,
            total_cents: quote.total_cents, currency: Order::CURRENCY
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
