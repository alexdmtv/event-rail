require "test_helper"

module Orders
  class CancellationTest < ActiveSupport::TestCase
    include Steps

    test "a cancellation is recorded at once and carried out in a job" do
      order = place
      clear_enqueued_jobs # its capture has not run

      TestSupport.request_cancellation(order.id)
      assert_equal [ "confirmed", "customer" ], [ order.reload.state, order.reload.cancel_reason ]
      assert_enqueued_jobs 1, only: CancelJob

      perform_enqueued_jobs(only: CancelJob)
      assert_equal "cancelled", order.reload.state
      assert_equal 10, available("MUG")
      assert Payments::TestSupport.release_requested?(order.reference), "the money is to be given back"
    end

    test "cancelling a paid order before dispatch releases the stock, calls off the shipment and asks for the money back" do
      order = place
      pay(order)
      assert_equal :requested, Fulfillment::TestSupport.shipment_status(order.reference)

      perform_enqueued_jobs(only: CancelJob) { TestSupport.request_cancellation(order.id) }

      assert_equal [ "cancelled", "cancelled" ], [ order.reload.state, order.status ]
      assert_equal 10, available("MUG")
      assert_equal :cancelled, Fulfillment::TestSupport.shipment_status(order.reference)
      assert Payments::TestSupport.release_requested?(order.reference)
    end

    test "a cancellation's refund is not announced as a return's" do
      order = place
      pay(order)
      perform_enqueued_jobs(only: CancelJob) { TestSupport.request_cancellation(order.id) }

      published = record_publications { refund(order) }

      assert_equal "cancelled", order.reload.status
      assert_not_includes published.map(&:event_type), "orders.order_refunded"
    end

    test "a cancellation's refused refund sets the order aside for a person, once" do
      order = place
      pay(order)
      perform_enqueued_jobs(only: CancelJob) { TestSupport.request_cancellation(order.id) }

      published = record_publications { refuse_refund(order) }

      assert_equal [ "needs_attention", "refund refused" ], [ order.reload.status, order.refund_failure_reason ]
      assert_not_includes published.map(&:event_type), "orders.order_refunded"
      assert_no_changes(-> { order.reload.attributes }) { refuse_refund(order, reason: "again") }
    end

    test "a refused refund for an order neither cancelled nor returning changes nothing" do
      order = place
      pay(order)

      assert_no_changes(-> { order.reload.attributes }) { refuse_refund(order, reason: "stray") }
    end

    test "an order that has shipped cannot be cancelled" do
      order = place
      pay(order)
      ship(order)

      assert_raises(NotCancellable) { TestSupport.request_cancellation(order.id) }
    end

    test "a cancellation requested once the parcel left, before Orders heard, is refused, and the order carries on" do
      Fulfillment::TestSupport.slow_carrier
      order = place
      pay(order)
      Fulfillment::TestSupport.carrier_collects_parcels # Orders has not heard yet

      perform_enqueued_jobs(only: CancelJob) { TestSupport.request_cancellation(order.id) }

      assert order.reload.cancellation_refused_at, "Fulfillment refused: the parcel had left"
      assert_equal "paid", order.status
      ship(order)
      assert_equal "shipped", order.reload.status
    end

    test "a refused cancellation replayed after the order was delivered and returned changes nothing" do
      Fulfillment::TestSupport.slow_carrier
      order = place
      pay(order)
      Fulfillment::TestSupport.carrier_collects_parcels
      perform_enqueued_jobs(only: CancelJob) { TestSupport.request_cancellation(order.id) }
      ship(order)
      deliver(order)
      TestSupport.request_return(order.id)

      assert_no_changes -> { order.reload.attributes } do
        CancelJob.perform_now(order.reload)
      end
      assert_equal "returning", order.reload.status
    end

    test "cancelling twice changes nothing and announces nothing further" do
      order = place
      perform_enqueued_jobs(only: CancelJob) { TestSupport.request_cancellation(order.id) }

      published = record_publications { perform_enqueued_jobs(only: CancelJob) { TestSupport.request_cancellation(order.id, reason: "again") } }

      assert_equal "customer", order.reload.cancel_reason
      assert_empty published
    end

    test "a cancellation requested while the queue is unavailable is carried out once it recovers" do
      order = place
      clear_enqueued_jobs
      refusing_enqueue { TestSupport.request_cancellation(order.id) }

      published = record_publications do
        relay_staged_jobs
        perform_enqueued_jobs(only: CancelJob)
      end

      assert_equal "cancelled", order.reload.state
      assert_includes published.map(&:event_type), "orders.order_cancelled"
    end

    test "a cancellation interrupted after its announcement announces again under the same identity" do
      order = place
      clear_enqueued_jobs
      TestSupport.request_cancellation(order.id)
      first = record_publications { failing(Payments::Api, :request_release) { perform_enqueued_jobs(only: CancelJob) } }
      again = record_publications { perform_enqueued_jobs(only: CancelJob) }

      cancelled = (first + again).select { |publication| publication.event_type == "orders.order_cancelled" }
      assert_equal 1, cancelled.size, "the first run failed before announcing"
      assert_equal 10, available("MUG")
    end
  end
end
