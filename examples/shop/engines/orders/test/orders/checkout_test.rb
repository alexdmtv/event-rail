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
      assert_nil Payments::Api.payment("key-1")
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

    test "a retry resumes a checkout whose follow-up was never scheduled" do
      FollowUpJob.define_singleton_method(:perform_later_as) { |*| raise "queue unavailable" }
      assert_raises(RuntimeError) { checkout }
      FollowUpJob.singleton_class.remove_method(:perform_later_as)
      assert_no_enqueued_jobs

      order = nil
      published = record_publications { perform_enqueued_jobs { order = checkout } }

      assert_equal 1, Orders::Order.count
      assert_equal "delivered", order_record(order).state
      assert_equal 1, published.count { |publication| publication.event_type == "orders.order_placed" }
    end

    test "a resumed follow-up announces the order under the same event identity" do
      order = checkout
      first = record_publications { perform_enqueued_jobs(only: FollowUpJob) }
      Orders::Order.where(id: order.id).update_all(state: "placed")

      checkout
      second = record_publications { perform_enqueued_jobs(only: FollowUpJob) }

      assert_equal first.map(&:event_id), second.map(&:event_id)
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
