module Catalog
  # Catalog's public surface. Every method is synchronous, because its callers cannot
  # continue without the answer: checkout must know the price and whether the stock exists
  # before it can accept an order. Results are plain values, never records.
  module Api
    Line = Data.define(:sku, :name, :quantity, :unit_price_cents) do
      def total_cents = quantity * unit_price_cents
    end
    Quote = Data.define(:lines) do
      def total_cents = lines.sum(&:total_cents)
    end

    class << self
      # Which of these SKUs the shop sells no product under, in one query.
      def unknown_skus(skus) = skus.uniq - Catalog::Product.where(sku: skus).pluck(:sku)

      # items: { "sku" => quantity }, priced in one query. Raises UnknownProduct.
      def quote(items)
        products = Catalog::Product.where(sku: items.keys).index_by(&:sku)
        Quote.new(lines: items.map do |sku, quantity|
          product = products[sku] or raise UnknownProduct, "unknown product #{sku}"
          Line.new(sku: product.sku, name: product.name, quantity: Integer(quantity), unit_price_cents: product.price_cents)
        end)
      end

      # Holds stock for every item or for none; items: { "sku" => positive Integer }.
      # Repeating a reservation ID holds nothing more, so a repeated command cannot
      # double-reserve. Raises OutOfStock or InvalidQuantity.
      def reserve(reservation_id:, items:) = Catalog::Reservation.hold(reservation_id, items).then { true }

      # Gives held stock back. Releasing twice, or releasing nothing, changes nothing.
      def release(reservation_id:) = Catalog::Reservation.for(reservation_id).release.then { true }

      # Turns a reservation into goods that left the warehouse. Shipping twice changes nothing.
      def ship(reservation_id:) = Catalog::Reservation.for(reservation_id).ship.then { true }

      # Puts goods that came back into the warehouse. Restocking twice changes nothing.
      def restock(reservation_id:) = Catalog::Reservation.for(reservation_id).restock.then { true }
    end
  end
end
