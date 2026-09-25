require "test_helper"
require_relative "../support/order_records"

module Orders
  class CancellationTest < ActiveSupport::TestCase
    include ShopHelpers
    include OrderRecords

    setup do
      stock_shelves
      slow_carrier
    end

    test "cancelling before capture releases the stock and voids the authorization" do
      order = checkout

      published = record_publications { perform_enqueued_jobs { Api.cancel(order.id) } }

      assert_equal "cancelled", order_record(order).state
      assert_equal 10, available("MUG")
      assert_equal "voided", Payments::Api.payment(order.reference).state
      assert_includes published.map(&:event_type), "orders.order_cancelled"
    end

    test "cancelling after capture, before dispatch, releases the stock and refunds the payment" do
      order = checkout
      perform_due_jobs
      assert_equal "paid", order_record(order).state

      perform_enqueued_jobs(at: Time.current) { Api.cancel(order.id) }

      assert_equal "cancelled", order_record(order).state
      assert_equal 10, available("MUG")
      assert_equal "refunded", Payments::Api.payment(order.reference).state
    end

    test "a capture that lands after the cancellation is refunded" do
      order = checkout
      perform_enqueued_jobs(only: FollowUpJob) # the capture is now queued, not yet performed
      Api.cancel(order.id)                     # the void is queued behind it

      perform_due_jobs                         # the capture lands first; the void finds nothing to void

      assert_equal "refunded", Payments::Api.payment(order.reference).state
      assert_equal "cancelled", order_record(order).state
    end

    test "a dispatched order cannot be cancelled" do
      Platform::FaultSettings.current.update!(carrier_delay_seconds: 0)
      order = nil
      perform_enqueued_jobs { order = checkout }

      error = assert_raises(Api::NotCancellable) { Api.cancel(order.id) }
      assert_match(/request a return/, error.message)
    end

    test "cancelling twice changes nothing and announces nothing further" do
      order = checkout
      Api.cancel(order.id)

      published = record_publications do
        assert_no_enqueued_jobs { Api.cancel(order.id) }
      end

      assert_empty published
    end

    test "a cancellation that crashed before its announcement is announced by the next attempt" do
      order = checkout
      Orders::Order.where(id: order.id).update_all(state: "cancelled", cancel_reason: "customer", cancelled_at: Time.current)

      published = record_publications { Api.cancel(order.id) }

      assert_equal [ "orders.order_cancelled" ], published.map(&:event_type)
      assert order_record(order).cancellation_announced_at?
    end

    test "a cancellation joins the order's flow" do
      order = checkout

      published = record_publications { Api.cancel(order.id) }

      assert_equal [ order.correlation_id ], published.map(&:correlation_id)
    end
  end
end
