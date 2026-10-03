module Catalog
  # One row per product, sharing the caller's reservation ID. on_hand is what is physically in the
  # warehouse, so a hold leaves it alone. Each step moves only rows still in its starting state.
  class Reservation < ApplicationRecord
    belongs_to :product

    scope :held, -> { where(state: "held") }
    scope :for, ->(reservation_id) { where(reservation_id: reservation_id) }

    # All items or none; repeating a reservation ID holds nothing more. Products are locked in
    # SKU order so two reservations sharing products cannot deadlock.
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

    def self.release = held.update_all(state: "released", updated_at: Time.current)

    def self.ship
      transaction do
        held.lock.each do |reservation|
          Product.update_counters(reservation.product_id, on_hand: -reservation.quantity)
          reservation.update!(state: "shipped")
        end
      end
    end

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
