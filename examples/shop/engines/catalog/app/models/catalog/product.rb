module Catalog
  class Product < ApplicationRecord
    # The shop sells in one currency; a second one would give each product a price per currency.
    CURRENCY = "EUR"

    has_many :reservations, dependent: :restrict_with_exception

    validates :sku, :name, presence: true
    validates :price_cents, :on_hand, numericality: { greater_than_or_equal_to: 0 }

    def self.find_by_sku!(sku) = find_by(sku: sku) || raise(UnknownProduct, "unknown product #{sku}")

    def available = on_hand - reservations.held.sum(:quantity)
  end
end
