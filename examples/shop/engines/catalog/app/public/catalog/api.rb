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

    class Error < StandardError; end
    class UnknownProduct < Error; end
    class OutOfStock < Error
      attr_reader :sku

      def initialize(sku)
        @sku = sku
        super("#{sku} is out of stock")
      end
    end

    class << self
      def products
        Catalog::Product.order(:name).map { |product| product_value(product) }
      end

      def product(sku) = product_value(find!(sku))

      # Adds a product to the catalog with its opening stock.
      def add_product(sku:, name:, price_cents:, on_hand:)
        product_value(Catalog::Product.create!(sku: sku, name: name, price_cents: price_cents, on_hand: on_hand))
      end

      # items: { "sku" => quantity }
      def quote(items)
        Quote.new(lines: items.map do |sku, quantity|
          product = find!(sku)
          Line.new(sku: product.sku, name: product.name, quantity: Integer(quantity), unit_price_cents: product.price_cents)
        end)
      end

      # Holds stock for every item or for none. Repeating a reservation ID holds nothing
      # more, so a retried checkout cannot double-reserve.
      def reserve(reservation_id:, items:)
        Catalog::Product.transaction do
          return true if Catalog::Reservation.exists?(reservation_id: reservation_id)

          items.each do |sku, quantity|
            product = find!(sku).lock!
            raise OutOfStock, sku if product.available < Integer(quantity)

            product.reservations.create!(reservation_id: reservation_id, quantity: Integer(quantity))
          end
        end
        true
      end

      # Gives held stock back. Releasing twice, or releasing nothing, changes nothing.
      def release(reservation_id:)
        Catalog::Reservation.held.where(reservation_id: reservation_id).update_all(state: "released", updated_at: Time.current)
        true
      end

      # Turns a reservation into goods that left the warehouse.
      def ship(reservation_id:)
        Catalog::Product.transaction do
          Catalog::Reservation.held.where(reservation_id: reservation_id).find_each do |reservation|
            reservation.product.lock!.decrement!(:on_hand, reservation.quantity)
            reservation.update!(state: "shipped")
          end
        end
        true
      end

      # Puts goods that came back into the warehouse. Restocking twice changes nothing.
      def restock(reservation_id:)
        Catalog::Product.transaction do
          Catalog::Reservation.where(reservation_id: reservation_id, state: "shipped").find_each do |reservation|
            reservation.product.lock!.increment!(:on_hand, reservation.quantity)
            reservation.update!(state: "restocked")
          end
        end
        true
      end

      private
        def find!(sku) = Catalog::Product.find_by(sku: sku) || raise(UnknownProduct, "unknown product #{sku}")

        def product_value(product)
          Product.new(sku: product.sku, name: product.name, price_cents: product.price_cents, on_hand: product.on_hand, available: product.available)
        end
    end
  end
end
