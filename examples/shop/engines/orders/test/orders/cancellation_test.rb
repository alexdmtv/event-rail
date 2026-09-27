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
      order = place

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
      order = place         # the capture is now queued, not yet performed
      Api.cancel(order.id)  # the void is queued behind it

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
      order = place
      perform_enqueued_jobs { Api.cancel(order.id) }

      published = record_publications do
        assert_no_enqueued_jobs { Api.cancel(order.id) }
      end

      assert_empty published
    end

    test "a cancellation made while the queue is unavailable is completed once it recovers" do
      order = place
      clear_enqueued_jobs # its capture has not run
      queue_adapter.define_singleton_method(:enqueue) { |*| raise "queue unavailable" }
      Api.cancel(order.id) # the decision and its job commit together
      queue_adapter.singleton_class.remove_method(:enqueue)
      assert_equal "cancelled", order_record(order).state

      published = record_publications do
        travel(Platform::StagedJob::GRACE + 1.second) { Platform::StagedJobRelayJob.perform_now }
        perform_due_jobs
      end

      assert_equal 10, available("MUG")
      assert_equal "voided", Payments::Api.payment(order.reference).state
      assert_equal 1, published.count { |publication| publication.event_type == "orders.order_cancelled" }
    ensure
      queue_adapter.singleton_class.remove_method(:enqueue) if queue_adapter.singleton_class.method_defined?(:enqueue, false)
    end

    test "a cancellation interrupted after its announcement announces again under the same identity" do
      order = place
      Api.cancel(order.id)
      first = record_publications { interrupting_after(EventRail, :publish) { perform_enqueued_jobs(only: CancellationJob) } }

      second = record_publications { work_off_queue } # its retry

      announcements = (first + second).select { |publication| publication.event_type == "orders.order_cancelled" }
      assert_equal 2, announcements.size
      assert_equal 1, announcements.map(&:event_id).uniq.size
      assert order_record(order).cancellation_announced_at?
    end

    test "an order still being placed, or rejected, cannot be cancelled" do
      pending_order = checkout
      assert_raises(Api::NotCancellable) { Api.cancel(pending_order.id) }
      clear_enqueued_jobs # it stays pending

      Payments::Gateway.adapter = ScriptedGateway.new(authorize: [ :refuse ])
      rejected = place(key: "key-2")
      assert_raises(Api::NotCancellable) { Api.cancel(rejected.id) }
      assert_nil Fulfillment::Api.shipment(rejected.reference), "Fulfillment was never asked"
    end

    test "a cancellation joins the order's flow" do
      order = place

      published = record_publications { perform_enqueued_jobs { Api.cancel(order.id) } }

      assert_equal [ order.correlation_id ], published.map(&:correlation_id).uniq
    end
  end
end
