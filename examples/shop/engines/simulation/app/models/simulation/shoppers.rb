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

    def tick
      orders_this_second.times { place_an_order }
      cancel_an_order if rand < @settings.cancel_rate / 10
      return_an_order if rand < @settings.return_rate / 10
      restock_low_shelves
    end

    private
      # A rate of 20 a minute is a third of an order a second: always the whole part, and the
      # fraction by chance.
      def orders_this_second
        per_second = @settings.orders_per_minute / 60.0
        per_second.floor + (rand < per_second % 1 ? 1 : 0)
      end

      def place_an_order
        customer = Customer.order("RANDOM()").first or return
        Orders::Api.checkout(customer: customer.snapshot, items: basket, key: "sim-#{SecureRandom.hex(8)}")
        @settings.increment!(:placed_count)
      rescue Orders::Api::Error => rejection
        @settings.update!(rejected_count: @settings.rejected_count + 1, last_rejection: rejection.message)
      end

      def basket
        Catalog::Api.products.select { |product| product.available.positive? }.sample(rand(1..3)).to_h do |product|
          [ product.sku, rand(1..[ product.available, 2 ].min) ]
        end
      end

      def cancel_an_order
        order = Orders::Api.recent(limit: 30).select(&:cancellable?).sample or return
        Orders::Api.cancel(order.id, reason: "customer changed their mind")
      rescue Orders::Api::NotCancellable
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
