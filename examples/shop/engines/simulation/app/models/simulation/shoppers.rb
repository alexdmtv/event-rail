module Simulation
  # One second of the outside world: customers check out at the configured rate, some cancel
  # an order that has not shipped, some return one that was delivered, and the supplier tops
  # up any shelf running low.
  class Shoppers
    LOW_STOCK = 20
    RESTOCK = 150

    def initialize(settings = Settings.current)
      @settings = settings
    end

    # Cancellations and returns keep pace with orders: at a cancel rate of 10 percent, one
    # cancellation for every ten orders placed, aimed at a recent order that has not shipped.
    def tick
      per_second = @settings.orders_per_minute / 60.0
      occurrences(per_second).times { place_an_order }
      occurrences(per_second * @settings.cancel_rate).times { cancel_an_order }
      occurrences(per_second * @settings.return_rate).times { return_an_order }
      restock_low_shelves
    end

    private
      # A rate of 20 a minute is a third of an order a second: always the whole part, and the
      # fraction by chance.
      def occurrences(per_second) = per_second.floor + (rand < per_second % 1 ? 1 : 0)

      def place_an_order
        customer = Customer.order("RANDOM()").first or return
        cart = Orders::Api.open_cart(customer: customer.snapshot, items: basket)
        Orders::Api.place_order(cart.id)
        @settings.increment!(:checkout_count)
      rescue Orders::Error => refusal # an order cancelled later shows in Orders' own counts
        @settings.increment!(:refused_count)
        @settings.update!(last_refusal: refusal.message)
      end

      def basket
        Catalog::Api.products.select { |product| product.available.positive? }.sample(rand(1..3)).to_h do |product|
          [ product.sku, rand(1..[ product.available, 2 ].min) ]
        end
      end

      def cancel_an_order
        order = Orders::Api.recent(limit: 30).select(&:cancellable?).sample or return
        Orders::Api.request_cancellation(order.id, reason: "customer changed their mind")
      rescue Orders::NotCancellable
        nil # it shipped while the customer was deciding
      end

      def return_an_order
        order = Orders::Api.recent(limit: 60).select(&:returnable?).sample or return
        Orders::Api.request_return(order.id)
      end

      def restock_low_shelves
        Catalog::Api.products.each do |product|
          Catalog::Api.receive_stock(sku: product.sku, quantity: RESTOCK) if product.available < LOW_STOCK
        end
      end
  end
end
