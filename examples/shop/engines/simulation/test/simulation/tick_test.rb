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

    test "starting the server switches a simulator left running off, and keeps its rate" do
      Api.configure(orders_per_minute: 30, cancel_rate: 0.1, return_rate: 0)
      Api.start

      Simulation::Engine.switch_simulator_off # what the engine does when the server boots

      assert_not Api.state.running
      assert_equal 30, Api.state.orders_per_minute
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
      assert orders.all? { |order| order.checkout_key.start_with?("sim-") }
      assert_equal 2, Api.state.checkout_count
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

    test "a checkout refused at once is counted, not raised" do
      Catalog::Api.reserve(reservation_id: "everything", items: { "MUG" => 500 }) # nothing left to put in a basket
      Api.start

      Api.tick

      assert_equal 2, Api.state.refused_count
      assert_match(/at least one item/, Api.state.last_refusal)
    end

    test "a declined card leaves a rejected order, as for any client" do
      Platform::FaultSettings.current.update!(authorization_decline_rate: 1.0)
      Api.start

      Api.tick
      work_off_queue

      assert_equal %w[ rejected rejected ], Orders::Api.recent.map(&:state)
      assert_equal 0, Api.state.refused_count
    end

    test "cancellations keep pace with orders at the cancel rate" do
      Api.start
      Api.tick
      perform_enqueued_jobs(only: ->(job) { job.fetch(:job).name == "Orders::PlaceOrderJob" })
      Api.configure(orders_per_minute: 120, cancel_rate: 1.0, return_rate: 0)

      Api.tick

      assert_equal 2, Orders::Api.recent.count { |order| order.state == "cancelled" }
    end

    test "returns keep pace with orders at the return rate" do
      Platform::FaultSettings.current.update!(carrier_delay_seconds: 0)
      Orders::Api.checkout(customer: Customer.sole.snapshot, items: { "MUG" => 1 }, key: "delivered-earlier")
      work_off_queue
      Api.configure(orders_per_minute: 60, cancel_rate: 0, return_rate: 1.0)
      Api.start

      Api.tick

      assert_equal "awaiting_return", Orders::Api.recent.find { |order| order.checkout_key == "delivered-earlier" }.state
    end
  end
end
