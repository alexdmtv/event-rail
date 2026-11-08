module Catalog
  # What other modules' tests and the host's may use of Catalog: setup in Catalog's terms, and
  # readers that answer with values, never records, so Catalog can change inside without breaking
  # anyone else's tests. The shelves themselves are Catalog's fixtures.
  module TestSupport
    def self.receive_stock(sku:, quantity:) = Product.find_by_sku!(sku).receive(quantity).then { nil }

    # Units on the shelf, and of those the ones no order holds.
    def self.on_hand(sku) = Product.find_by_sku!(sku).on_hand
    def self.available(sku) = Product.find_by_sku!(sku).available
  end
end
