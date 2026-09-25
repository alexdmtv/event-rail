require "test_helper"

module Simulation
  class TickTest < ActiveSupport::TestCase
    setup do
      Catalog::Api.add_product(sku: "MUG", name: "Stoneware mug", price_cents: 1490, on_hand: 500)
      Customer.create!(customer_id: "cus_1", name: "Ada Lovelace", email: "ada@example.com", address: "London")
      Api.configure(orders_per_minute: 120, cancel_rate: 0, return_rate: 0)
    end

    test "the simulator starts off" do
      assert_not Api.state.running
    end

    test "a tick while the simulator is off places nothing" do
      Api.tick

      assert_empty Orders::Api.recent
    end

    test "a tick while the simulator is on places orders like any client, with checkout keys" do
      Api.start

      Api.tick

      orders = Orders::Api.recent
      assert_equal 2, orders.size
      assert orders.all? { |order| order.reference.start_with?("sim-") }
      assert_equal 2, Api.state.placed_count
    end

    test "each simulated checkout starts its own flow" do
      Api.start

      Api.tick

      assert_equal 2, Orders::Api.recent.map(&:correlation_id).uniq.size
    end

    test "the supplier refills a shelf running low" do
      Catalog::Api.add_product(sku: "TEA", name: "Green tea", price_cents: 890, on_hand: 3)
      Api.start

      Api.tick

      assert_operator Catalog::Api.product("TEA").on_hand, :>=, 150
    end

    test "a rejected checkout is counted, not raised" do
      Platform::FaultSettings.current.update!(authorization_decline_rate: 1.0)
      Api.start

      Api.tick

      assert_equal 2, Api.state.rejected_count
      assert_match(/declined/, Api.state.last_rejection)
    end

    test "cancellations keep pace with orders at the cancel rate" do
      Api.configure(orders_per_minute: 120, cancel_rate: 1.0, return_rate: 0)
      Api.start

      Api.tick

      assert_equal %w[ cancelled cancelled ], Orders::Api.recent.map(&:state)
    end

    test "returns keep pace with orders at the return rate" do
      Platform::FaultSettings.current.update!(carrier_delay_seconds: 0)
      Orders::Api.checkout(customer: Customer.sole.snapshot, items: { "MUG" => 1 }, key: "delivered-earlier")
      work_off_queue
      Api.configure(orders_per_minute: 60, cancel_rate: 0, return_rate: 1.0)
      Api.start

      Api.tick

      assert_equal "awaiting_return", Orders::Api.recent.find { |order| order.reference == "delivered-earlier" }.state
    end
  end
end
