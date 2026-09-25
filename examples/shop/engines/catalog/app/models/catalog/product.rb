module Catalog
  class Product < ApplicationRecord
    has_many :reservations, dependent: :restrict_with_exception

    validates :sku, :name, presence: true
    validates :price_cents, :on_hand, numericality: { greater_than_or_equal_to: 0 }

    # Stock not held by a reservation.
    def available = on_hand - reservations.held.sum(:quantity)
  end
end
