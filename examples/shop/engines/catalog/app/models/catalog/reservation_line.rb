module Catalog
  # One product's share of a reservation; only the reservation creates it.
  class ReservationLine < ApplicationRecord
    belongs_to :reservation
    belongs_to :product

    attr_readonly :reservation_id, :product_id, :quantity

    scope :held, -> { joins(:reservation).merge(Reservation.held) }
  end
end
