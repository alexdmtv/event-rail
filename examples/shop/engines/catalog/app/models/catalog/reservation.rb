module Catalog
  # Stock held for a caller, one row per product, all sharing the caller's reservation ID.
  # `on_hand` counts what is physically in the warehouse; a held reservation makes part of it
  # unavailable without moving it. Every step is safe to repeat: each moves only the rows still
  # in the state it starts from.
  class Reservation < ApplicationRecord
    belongs_to :product

    scope :held, -> { where(state: "held") }
    scope :for, ->(reservation_id) { where(reservation_id: reservation_id) }

    # Holds stock for every item or for none; items: { "sku" => positive Integer }. Repeating
    # a reservation ID holds nothing more.
    #
    # One reservation spans several products, and each product guards its own stock, so the
    # transaction takes several products' locks: taken in SKU order, so that two reservations
    # sharing products cannot deadlock.
    def self.hold(reservation_id, items)
      transaction do
        next if self.for(reservation_id).exists?

        items.sort.each do |sku, quantity|
          raise InvalidQuantity, "#{sku}: #{quantity.inspect} is not a positive quantity" unless quantity.is_a?(Integer) && quantity.positive?

          product = Product.find_by_sku!(sku).lock!
          raise OutOfStock, sku if product.available < quantity

          product.reservations.create!(reservation_id: reservation_id, quantity: quantity)
        end
      end
    end

    # Gives held stock back.
    def self.release = held.update_all(state: "released", updated_at: Time.current)

    # Turns held stock into goods that left the warehouse.
    def self.ship
      transaction do
        held.lock.each do |reservation|
          Product.update_counters(reservation.product_id, on_hand: -reservation.quantity)
          reservation.update!(state: "shipped")
        end
      end
    end

    # Puts goods that came back into the warehouse.
    def self.restock
      transaction do
        where(state: "shipped").lock.each do |reservation|
          Product.update_counters(reservation.product_id, on_hand: reservation.quantity)
          reservation.update!(state: "restocked")
        end
      end
    end
  end
end
