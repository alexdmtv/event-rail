module Catalog
  # One product's share of a reservation; only the reservation creates it.
  class ReservationLine < ApplicationRecord
    belongs_to :reservation
    belongs_to :product

    scope :held, -> { joins(:reservation).merge(Reservation.held) }
  end
end
