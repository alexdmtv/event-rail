require "test_helper"
require_relative "../support/order_records"

module Orders
  class CheckoutTest < ActiveSupport::TestCase
    include ShopHelpers
    include OrderRecords

    setup { stock_shelves }

    test "a successful checkout places the order, reserves the stock and authorizes the card" do
      order = checkout

      assert_equal "placed", order.state
      assert_equal 2 * 1490 + 890, order.total_cents
      assert_equal 8, available("MUG")
      assert_equal "authorized", Payments::Api.payment(order.reference).state
    end

    test "an out-of-stock item rejects the checkout and leaves nothing behind" do
      assert_raises(Api::OutOfStock) { checkout(items: { "TEA" => 1, "MUG" => 11 }) }

      assert_equal 0, Orders::Order.count
      assert_equal 10, available("TEA")
    end

    test "a basket with a quantity that is not a whole number is refused before anything is held" do
      Payments::Gateway.adapter = gateway = ScriptedGateway.new

      [ -2, "-2", "1.5", 1.5, "two", nil ].each do |quantity|
        assert_raises(Api::InvalidQuantity, quantity.inspect) { checkout(items: { "MUG" => quantity }) }
      end
      assert_raises(Api::EmptyBasket) { checkout(items: { "MUG" => 0, "TEA" => "0" }) }

      assert_equal 0, gateway.calls[:authorize]
      assert_equal 10, available("MUG")
      assert_equal 0, Orders::Order.count
    end

    test "a retry after a declined card is a new attempt that holds its own stock" do
      Payments::Gateway.adapter = ScriptedGateway.new(authorize: [ :refuse ])
      assert_raises(Api::PaymentDeclined) { checkout }
      assert_equal 10, available("MUG")

      order = checkout
      assert_equal 8, available("MUG")
      assert_equal "authorized", Payments::Api.payment(order.reference).state

      work_off_queue
      assert_equal "delivered", order_record(order).state
      assert_equal 8, on_hand("MUG"), "the delivered items left the warehouse's stock"
    end

    test "a retry while the failed attempt's void is still queued keeps an authorization of its own" do
      Orders::Order.define_singleton_method(:create!) { |*| raise ActiveRecord::StatementTimeout, "database busy" }
      assert_raises(ActiveRecord::StatementTimeout) { checkout }
      Orders::Order.singleton_class.remove_method(:create!)
      # The failed attempt's void is queued, not yet run. (By name: Payments' jobs are private.)
      assert_equal 1, enqueued_jobs.count { |job| job["job_class"] == "Payments::VoidJob" }

      order = checkout
      work_off_queue

      assert_equal "delivered", order_record(order).state
      assert_equal "captured", Payments::Api.payment(order.reference).state
      assert_equal 8, on_hand("MUG")
    ensure
      Orders::Order.singleton_class.remove_method(:create!) if Orders::Order.singleton_class.method_defined?(:create!, false)
    end

    test "two attempts racing to record the same key make one order and leave it whole" do
      winner = checkout
      loser = Checkout.new(customer: ShopHelpers::CUSTOMER, items: { "MUG" => 2, "TEA" => 1 }, key: "key-1")
      lookups = 0
      # The loser looked for an order before the winner committed, so it runs as an attempt of
      # its own, and meets the winner only at the unique checkout key.
      loser.define_singleton_method(:existing_order) { (lookups += 1) == 1 ? nil : super() }

      returned = loser.call

      assert_equal winner.id, returned.id
      assert_equal 1, Orders::Order.count
      assert_equal 8, available("MUG"), "the loser gave back its own reservation and nothing more"
      work_off_queue
      assert_equal "delivered", order_record(winner).state
      assert_equal "captured", Payments::Api.payment(winner.reference).state
      assert_equal 8, on_hand("MUG")
    end

    test "each attempt has a reference of its own under the checkout key" do
      order = checkout

      assert_equal "key-1", order.checkout_key
      assert_match %r{\Akey-1/\h+\z}, order.reference
    end

    test "a declined card rejects the checkout and releases the reservation" do
      Payments::Gateway.adapter = ScriptedGateway.new(authorize: [ :refuse ])

      assert_raises(Api::PaymentDeclined) { checkout }

      assert_equal 0, Orders::Order.count
      assert_equal 10, available("MUG")
    end

    test "submitting the same checkout again returns the same order with a single authorization" do
      Payments::Gateway.adapter = gateway = ScriptedGateway.new

      first = checkout
      second = checkout

      assert_equal first.id, second.id
      assert_equal 1, gateway.calls[:authorize]
      assert_equal 8, available("MUG")
    end

    test "a repeated checkout starts the order's follow-up once" do
      checkout
      checkout

      assert_equal 1, enqueued_jobs.count { |job| job["job_class"] == FollowUpJob.name }
    end

    test "an order whose follow-up the queue could not take at the commit is delivered without a retry" do
      queue_adapter.define_singleton_method(:enqueue) { |*| raise "queue unavailable" }
      order = checkout # accepted: the follow-up is staged with the order
      queue_adapter.singleton_class.remove_method(:enqueue)
      assert_no_enqueued_jobs

      travel(Platform::StagedJob::GRACE + 1.second) { Platform::StagedJobRelayJob.perform_now }
      work_off_queue

      assert_equal "delivered", order_record(order).state
    ensure
      queue_adapter.singleton_class.remove_method(:enqueue) if queue_adapter.singleton_class.method_defined?(:enqueue, false)
    end

    test "a follow-up handed to the queue twice announces the order under one event identity" do
      checkout
      # As if the first hand-over had crashed after enqueuing and before deleting its row.
      staged = enqueued_jobs.sole.except(:job, :args, :queue, :priority, :at)
      Platform::StagedJob.create!(job_id: staged["job_id"], job_class: FollowUpJob.name, payload: staged, created_at: 1.minute.ago)
      Platform::StagedJobRelayJob.perform_now
      assert_equal 2, enqueued_jobs.count { |job| job["job_class"] == FollowUpJob.name }

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

    test "an empty basket is refused" do
      assert_raises(Api::EmptyBasket) { checkout(items: {}) }
    end

    test "an order is found by the correlation its checkout opened" do
      order = checkout

      assert_equal order, Api.order_for_correlation(order.correlation_id)
      assert_nil Api.order_for_correlation("unknown")
    end
  end
end
