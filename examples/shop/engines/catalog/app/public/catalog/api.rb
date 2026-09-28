module Catalog
  # Catalog's public surface. Every method is synchronous, because its callers cannot
  # continue without the answer: checkout must know the price and whether the stock exists
  # before it can accept an order. Results are plain values, never records.
  module Api
    Product = Data.define(:sku, :name, :price_cents, :on_hand, :available)
    Line = Data.define(:sku, :name, :quantity, :unit_price_cents) do
      def total_cents = quantity * unit_price_cents
    end
    Quote = Data.define(:lines) do
      def total_cents = lines.sum(&:total_cents)
    end

    class << self
      def products = Catalog::Product.order(:name).map { |product| product_value(product) }

      def product(sku) = product_value(Catalog::Product.find_by_sku!(sku))

      # Adds a product to the catalog with its opening stock.
      def add_product(sku:, name:, price_cents:, on_hand:)
        product_value(Catalog::Product.create!(sku: sku, name: name, price_cents: price_cents, on_hand: on_hand))
      end

      # items: { "sku" => quantity }
      def quote(items)
        Quote.new(lines: items.map do |sku, quantity|
          product = Catalog::Product.find_by_sku!(sku)
          Line.new(sku: product.sku, name: product.name, quantity: Integer(quantity), unit_price_cents: product.price_cents)
        end)
      end

      # Holds stock for every item or for none; items: { "sku" => positive Integer }.
      # Repeating a reservation ID holds nothing more, so a repeated command cannot
      # double-reserve. Raises OutOfStock or InvalidQuantity.
      def reserve(reservation_id:, items:) = Catalog::Reservation.hold(reservation_id, items).then { true }

      # A delivery from a supplier arrived.
      def receive_stock(sku:, quantity:) = Catalog::Product.find_by_sku!(sku).receive(quantity).then { true }

      # Gives held stock back. Releasing twice, or releasing nothing, changes nothing.
      def release(reservation_id:) = Catalog::Reservation.for(reservation_id).release.then { true }

      # Turns a reservation into goods that left the warehouse. Shipping twice changes nothing.
      def ship(reservation_id:) = Catalog::Reservation.for(reservation_id).ship.then { true }

      # Puts goods that came back into the warehouse. Restocking twice changes nothing.
      def restock(reservation_id:) = Catalog::Reservation.for(reservation_id).restock.then { true }

      private
        def product_value(product)
          Product.new(sku: product.sku, name: product.name, price_cents: product.price_cents, on_hand: product.on_hand, available: product.available)
        end
    end
  end
end
