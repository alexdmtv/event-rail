module Catalog
  class Product < ApplicationRecord
    has_many :reservations, dependent: :restrict_with_exception

    validates :sku, :name, presence: true
    validates :price_cents, :on_hand, numericality: { greater_than_or_equal_to: 0 }

    def self.find_by_sku!(sku) = find_by(sku: sku) || raise(UnknownProduct, "unknown product #{sku}")

    # Stock not held by a reservation.
    def available = on_hand - reservations.held.sum(:quantity)

    # A delivery from a supplier arrived.
    def receive(quantity) = self.class.update_counters(id, on_hand: Integer(quantity))
  end
end
