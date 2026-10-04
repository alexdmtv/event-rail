module Catalog
  # on_hand is what is physically in the warehouse: a hold leaves it alone, and only goods
  # leaving or arriving change it.
  class Product < ApplicationRecord
    # The shop sells in one currency; a second one would give each product a price per currency.
    CURRENCY = "EUR"

    has_many :reservation_lines, dependent: :restrict_with_exception

    validates :sku, :name, presence: true
    validates :price_cents, :on_hand, numericality: { greater_than_or_equal_to: 0 }

    def self.find_by_sku!(sku) = find_by(sku: sku) || raise(UnknownProduct, "unknown product #{sku}")

    def available = on_hand - reservation_lines.held.sum(:quantity)

    # Call it on a product locked for the hold, so no other hold takes the same stock meanwhile.
    def ensure_available(quantity)
      raise OutOfStock, sku if available < quantity
    end

    # One statement each, so concurrent moves add up; the database keeps on_hand at zero or above.
    def withdraw(quantity) = self.class.update_counters(id, on_hand: -quantity)
    def receive(quantity) = self.class.update_counters(id, on_hand: quantity)
  end
end
