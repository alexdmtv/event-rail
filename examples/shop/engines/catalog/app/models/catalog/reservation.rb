module Catalog
  # Stock held for a caller until it is released, or restocked after a return. `on_hand`
  # counts what is physically in the warehouse; a held reservation makes part of it
  # unavailable without moving it.
  class Reservation < ApplicationRecord
    belongs_to :product

    scope :held, -> { where(state: "held") }
  end
end
