module Orders
  # A product and how many of it, in a cart. The product must be one the shop sells; its price
  # is read when the order is placed, not now.
  class CartItem < ApplicationRecord
    belongs_to :cart

    validates :sku, presence: true
    validates :quantity, numericality: { only_integer: true, greater_than: 0 }
    validate :product_is_sold, :listed_once, if: :sku?

    private
      # The table holds one row per product in a cart, so a request listing one twice is refused.
      def listed_once
        earlier = cart.items.take_while { |item| !item.equal?(self) }
        errors.add(:sku, :taken, message: "is listed more than once") if earlier.any? { |item| item.sku == sku }
      end

      def product_is_sold
        errors.add(:sku, :unknown_product, message: "is not a product the shop sells") unless cart.catalog_products.key?(sku)
      end
  end
end
