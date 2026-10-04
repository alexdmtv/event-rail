module Catalog
  module Api
    Product = Data.define(:sku, :name, :price_cents, :currency)
    Line = Data.define(:sku, :name, :quantity, :unit_price_cents) do
      def total_cents = quantity * unit_price_cents
    end
    Quote = Data.define(:lines, :currency) do
      def total_cents = lines.sum(&:total_cents)
    end

    class << self
      # An unknown SKU is left out, not raised.
      def products(skus) = Catalog::Product.where(sku: skus).map { |product| Product.new(sku: product.sku, name: product.name, price_cents: product.price_cents, currency: Catalog::Product::CURRENCY) }

      # items: { "sku" => quantity }. Raises UnknownProduct.
      def quote(items)
        products = Catalog::Product.where(sku: items.keys).index_by(&:sku)
        Quote.new(currency: Catalog::Product::CURRENCY, lines: items.map do |sku, quantity|
          product = products[sku] or raise UnknownProduct, "unknown product #{sku}"
          Line.new(sku: product.sku, name: product.name, quantity: Integer(quantity), unit_price_cents: product.price_cents)
        end)
      end

      # All items or none; items: { "sku" => positive Integer }, at least one. A reference holds
      # once: repeating it holds nothing more, whatever the items. Raises OutOfStock,
      # InvalidQuantity or UnknownProduct.
      def reserve(reference:, items:) = Catalog::Reservation.hold(reference, items).then { true }

      # Safe to repeat, and to call for a reference that holds nothing.
      def release(reference:) = Catalog::Reservation.find_by(reference:).then { |reservation| reservation&.release; true }

      # Takes the held stock off on_hand. Safe to repeat. Raises AlreadyReleased for a reservation
      # given up.
      def ship(reference:) = Catalog::Reservation.find_by(reference:).then { |reservation| reservation&.ship; true }

      # Puts shipped stock back on hand. Safe to repeat. Raises NotYetShipped while the stock is
      # still held, to be retried.
      def restock(reference:) = Catalog::Reservation.find_by(reference:).then { |reservation| reservation&.restock; true }
    end
  end
end
