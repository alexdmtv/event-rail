module Catalog
  module Api
    Product = Data.define(:sku, :name, :price_cents)
    Line = Data.define(:sku, :name, :quantity, :unit_price_cents) do
      def total_cents = quantity * unit_price_cents
    end
    Quote = Data.define(:lines) do
      def total_cents = lines.sum(&:total_cents)
    end

    class << self
      # An unknown SKU is left out, not raised.
      def products(skus) = Catalog::Product.where(sku: skus).map { |product| Product.new(sku: product.sku, name: product.name, price_cents: product.price_cents) }

      # items: { "sku" => quantity }. Raises UnknownProduct.
      def quote(items)
        products = Catalog::Product.where(sku: items.keys).index_by(&:sku)
        Quote.new(lines: items.map do |sku, quantity|
          product = products[sku] or raise UnknownProduct, "unknown product #{sku}"
          Line.new(sku: product.sku, name: product.name, quantity: Integer(quantity), unit_price_cents: product.price_cents)
        end)
      end

      # All items or none; items: { "sku" => positive Integer }. Repeating a reservation ID holds
      # nothing more. Raises OutOfStock, InvalidQuantity or UnknownProduct.
      def reserve(reservation_id:, items:) = Catalog::Reservation.hold(reservation_id, items).then { true }

      # Safe to repeat, and to call for a reservation that holds nothing.
      def release(reservation_id:) = Catalog::Reservation.for(reservation_id).release.then { true }

      # Takes the held stock off on_hand. Safe to repeat.
      def ship(reservation_id:) = Catalog::Reservation.for(reservation_id).ship.then { true }

      # Puts shipped stock back on hand. Safe to repeat.
      def restock(reservation_id:) = Catalog::Reservation.for(reservation_id).restock.then { true }
    end
  end
end
