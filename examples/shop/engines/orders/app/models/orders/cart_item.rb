module Orders
  # Holds no price: the order prices its items when it is placed.
  class CartItem < ApplicationRecord
    belongs_to :cart

    validates :sku, presence: true
    validates :quantity, numericality: { only_integer: true, greater_than: 0 }
    validate :product_is_sold, :listed_once, if: :sku?

    private
      # A unique index allows one row per product; checking here reports a duplicate as invalid
      # input rather than a database error.
      def listed_once
        earlier = cart.items.take_while { |item| !item.equal?(self) }
        errors.add(:sku, :taken, message: "is listed more than once") if earlier.any? { |item| item.sku == sku }
      end

      def product_is_sold
        errors.add(:sku, :unknown_product, message: "is not a product the shop sells") unless cart.catalog_products.key?(sku)
      end
  end
end
