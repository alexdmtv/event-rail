require "test_helper"
require_relative "../support/order_records"

module Orders
  class CheckoutTest < ActiveSupport::TestCase
    include ShopHelpers
    include OrderRecords

    setup { stock_shelves }

    test "checkout records a pending order, and placing it reserves the stock and authorizes the card" do
      pending_order = checkout
      assert_equal "pending", pending_order.state
      assert_equal 10, available("MUG"), "nothing is reserved within the request"

      order = place(key: "key-1")

      assert_equal pending_order.id, order.id
      assert_equal "placed", order.state
      assert_equal 2 * 1490 + 890, order.total_cents
      assert_equal 8, available("MUG")
      assert_equal "authorized", Payments::Api.payment(order.reference).state
    end

    test "an out-of-stock item rejects the order and leaves nothing held" do
      order = place(items: { "TEA" => 1, "MUG" => 11 })

      assert_equal "rejected", order.state
      assert_equal "MUG is out of stock", order.rejection_reason
      assert_equal 10, available("TEA")
      assert_nil Payments::Api.payment(order.reference)
    end

    test "a declined card rejects the order and releases its stock" do
      Payments::Gateway.adapter = ScriptedGateway.new(authorize: [ :refuse ])

      order = place
      perform_enqueued_jobs

      assert_equal "rejected", order.state
      assert_match(/\Apayment declined/, order.rejection_reason)
      assert_equal 10, available("MUG")
      assert_nil Payments::Api.payment(order.reference)
    end

    test "a payment provider that stays unavailable rejects the order after a few attempts" do
      Payments::Gateway.adapter = gateway = ScriptedGateway.new(authorize: [ :timeout ] * PlaceOrderJob::AUTHORIZATION_ATTEMPTS)
      order = checkout

      work_off_queue

      assert_equal PlaceOrderJob::AUTHORIZATION_ATTEMPTS, gateway.calls[:authorize]
      record = order_record(order)
      assert_equal "rejected", record.state
      assert_match(/\Apayment provider unavailable/, record.rejection_reason)
      assert_equal 10, available("MUG")
    end

    test "a basket that is empty or has a quantity that is not a whole number is refused, recording nothing" do
      Payments::Gateway.adapter = gateway = ScriptedGateway.new

      [ -2, "-2", "1.5", 1.5, "two", nil ].each do |quantity|
        assert_raises(Api::InvalidQuantity, quantity.inspect) { checkout(items: { "MUG" => quantity }) }
      end
      assert_raises(Api::EmptyBasket) { checkout(items: { "MUG" => 0, "TEA" => "0" }) }
      assert_raises(Api::EmptyBasket) { checkout(items: {}) }
      assert_raises(Api::UnknownProduct) { checkout(items: { "SPOON" => 1 }) }

      assert_equal 0, Orders::Order.count
      assert_no_enqueued_jobs
      assert_equal 0, gateway.calls[:authorize]
    end

    test "submitting the same checkout again returns the same order, placed once" do
      Payments::Gateway.adapter = gateway = ScriptedGateway.new

      first = checkout
      second = checkout
      work_off_queue
      third = checkout

      assert_equal [ first.id ] * 3, [ first, second, third ].map(&:id)
      assert_equal 1, gateway.calls[:authorize]
      assert_equal 8, on_hand("MUG")
      assert_equal "delivered", third.state
    end

    test "a repeat after a rejection returns the rejected order and places nothing" do
      Payments::Gateway.adapter = gateway = ScriptedGateway.new(authorize: [ :refuse ])
      rejected = place

      repeated = checkout
      perform_enqueued_jobs

      assert_equal rejected.id, repeated.id
      assert_equal "rejected", repeated.state
      assert_equal 1, gateway.calls[:authorize]
      assert_equal 10, available("MUG")
    end

    test "trying again after a rejection under a new key places a new order with stock of its own" do
      Payments::Gateway.adapter = ScriptedGateway.new(authorize: [ :refuse ])
      rejected = place(key: "key-1")

      order = place(key: "key-2")
      work_off_queue

      refute_equal rejected.id, order.id
      assert_equal "delivered", order_record(order).state
      assert_equal 8, on_hand("MUG"), "the delivered items left the warehouse's stock"
    end

    test "two submissions racing to record the same key make one order, and the loser takes nothing" do
      winner = checkout
      loser = Checkout.new(customer: ShopHelpers::CUSTOMER, items: { "MUG" => 2, "TEA" => 1 }, key: "key-1")
      lookups = 0
      # The loser looked for an order before the winner committed, so it tries to record one of
      # its own, and meets the winner at the unique checkout key.
      loser.define_singleton_method(:existing_order) { (lookups += 1) == 1 ? nil : super() }

      returned = loser.call

      assert_equal winner.id, returned.id
      assert_equal 1, Orders::Order.count
      assert_equal 1, enqueued_jobs.count { |job| job["job_class"] == PlaceOrderJob.name }, "the loser's staged placement rolled back"
      assert_equal 0, Platform::StagedJob.count
      work_off_queue
      assert_equal "delivered", order_record(winner).state
      assert_equal 8, on_hand("MUG")
    end

    test "placing interrupted after the reservation reserves once when it runs again" do
      order = checkout
      failing(Payments::Api, :authorize) { perform_enqueued_jobs(only: PlaceOrderJob) }
      assert_equal "pending", order_record(order).state

      work_off_queue

      assert_equal "delivered", order_record(order).state
      assert_equal 8, on_hand("MUG")
    end

    test "placing interrupted after the authorization is placed when it runs again, with one authorization" do
      Payments::Gateway.adapter = gateway = ScriptedGateway.new
      order = checkout
      interrupting_after(Payments::Api, :authorize) { perform_enqueued_jobs(only: PlaceOrderJob) }
      assert_equal "pending", order_record(order).state

      work_off_queue

      assert_equal "delivered", order_record(order).state
      assert_equal 1, gateway.calls[:authorize]
      assert_equal 8, on_hand("MUG")
    end

    test "placing interrupted after the order is placed announces it when it runs again" do
      order = checkout
      failing(EventRail, :publish) { perform_enqueued_jobs(only: PlaceOrderJob) }
      assert_equal "placed", order_record(order).state

      published = record_publications { work_off_queue }

      assert_equal 1, published.count { |publication| publication.event_type == "orders.order_placed" }
      assert_equal "delivered", order_record(order).state
    end

    test "placing interrupted after the announcement announces again under the same identity" do
      order = checkout
      first = record_publications { failing(Payments::Api, :capture) { perform_enqueued_jobs(only: PlaceOrderJob) } }

      again = record_publications { work_off_queue }

      placed = (first + again).select { |publication| publication.event_type == "orders.order_placed" }
      assert_equal 2, placed.size
      assert_equal 1, placed.map(&:event_id).uniq.size
      assert_equal "delivered", order_record(order).state
    end

    test "a rejection whose stock release fails and whose void is not enqueued gives both back on its retry" do
      Payments::Gateway.adapter = ScriptedGateway.new(authorize: [ :refuse ])
      order = checkout

      refusing_enqueue(only: "Payments::VoidJob") do |refused|
        failing(Catalog::Api, :release) { perform_enqueued_jobs(only: PlaceOrderJob) }
        assert_equal 1, refused.size, "the void was attempted although the release failed first"
      end
      assert_equal 8, available("MUG")

      work_off_queue

      record = order_record(order)
      assert_equal "rejected", record.state
      assert_match(/\Apayment declined/, record.rejection_reason, "the rejection keeps its reason")
      assert_equal 10, available("MUG")
    end

    test "an order whose placement the queue could not take at the commit is delivered without a retry" do
      order = refusing_enqueue { checkout } # recorded: the placement is staged with the order
      assert_no_enqueued_jobs

      relay_staged_jobs
      work_off_queue

      assert_equal "delivered", order_record(order).state
    end

    test "a placement handed to the queue twice announces the order under one event identity" do
      checkout
      # As if the first hand-over had crashed after enqueuing and before deleting its row.
      staged = enqueued_jobs.sole.except(:job, :args, :queue, :priority, :at)
      Platform::StagedJob.create!(job_id: staged["job_id"], job_class: PlaceOrderJob.name, payload: staged, created_at: 1.minute.ago)
      Platform::StagedJobRelayJob.perform_now
      assert_equal 2, enqueued_jobs.count { |job| job["job_class"] == PlaceOrderJob.name }

      published = record_publications { work_off_queue }

      placed = published.select { |publication| publication.event_type == "orders.order_placed" }
      assert_equal 2, placed.size
      assert_equal 1, placed.map(&:event_id).uniq.size
    end

    test "a key reused for a different basket is refused" do
      checkout

      assert_raises(Api::ConflictingKey) { checkout(items: { "TEA" => 3 }) }
    end

    test "the order's flow is correlated by its checkout" do
      order = nil
      published = record_publications { perform_enqueued_jobs { order = checkout } }

      assert_equal "checkout-key-1", order.correlation_id
      assert_includes published.map(&:event_type), "orders.order_delivered"
      assert published.all? { |publication| publication.correlation_id == order.correlation_id }
    end

    test "an order is found by the correlation its checkout opened" do
      order = checkout

      assert_equal order, Api.order_for_correlation(order.correlation_id)
      assert_nil Api.order_for_correlation("unknown")
    end
  end
end
