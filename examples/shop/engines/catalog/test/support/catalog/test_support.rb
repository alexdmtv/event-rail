module Catalog
  module TestSupport
    def self.add_product(sku:, name:, price_cents:, on_hand:) = Product.create!(sku:, name:, price_cents:, on_hand:)
    def self.receive_stock(sku:, quantity:) = Product.update_counters(Product.find_by_sku!(sku).id, on_hand: quantity)
    def self.product(sku) = Product.find_by_sku!(sku)
  end
end
