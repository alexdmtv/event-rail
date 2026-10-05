require "test_helper"

module Orders
  class CancellationTest < ActiveSupport::TestCase
    include ShopHelpers

    setup do
      stock_shelves
      slow_carrier
    end

    test "a cancellation is recorded at once and carried out in a job" do
      order = place
      clear_enqueued_jobs # its capture has not run

      TestSupport.request_cancellation(order.id)
      assert_equal [ "confirmed", "customer" ], [ order.reload.state, order.reload.cancel_reason ]
      assert_enqueued_jobs 1, only: CancelJob

      perform_due_jobs
      assert_equal "cancelled", order.reload.state
      assert_equal 10, available("MUG")
      assert_equal "voided", Payments::TestSupport.payment(order.reference).state
    end

    test "cancelling after capture, before dispatch, releases the stock and refunds the payment" do
      order = place
      perform_due_jobs # captured and paid; the carrier has not collected the parcel

      published = record_publications { perform_enqueued_jobs { TestSupport.request_cancellation(order.id) } }

      assert_equal [ "cancelled", "cancelled" ], [ order.reload.state, order.status ]
      assert_equal 10, available("MUG")
      assert_equal "refunded", Payments::TestSupport.payment(order.reference).state
      assert_not_includes published.map(&:event_type), "orders.order_refunded", "a cancellation's refund is not a return's"
    end

    test "a cancellation's refused refund sets the order aside for a person, once" do
      Payments::TestSupport.scripted_gateway(refund: [ :refuse ])
      order = place
      perform_due_jobs # captured and paid

      published = record_publications { perform_enqueued_jobs { TestSupport.request_cancellation(order.id) } }

      assert_equal [ "needs_attention", "refused by the script" ], [ order.reload.status, order.refund_failure_reason ]
      assert_not_includes published.map(&:event_type), "orders.order_refunded"
      assert_no_changes -> { order.reload.attributes } do
        RecordCancellationRefundFailureJob.perform_now(EventRail.publish(Payments::Events::RefundFailed.new(reference: order.reference, reason: "again")).event)
      end
    end

    test "a refused refund for an order neither cancelled nor returning changes nothing" do
      order = place
      perform_due_jobs

      assert_no_changes -> { order.reload.attributes } do
        RecordCancellationRefundFailureJob.perform_now(EventRail.publish(Payments::Events::RefundFailed.new(reference: order.reference, reason: "stray")).event)
      end
    end

    test "a capture that lands after the cancellation is refunded" do
      order = place
      perform_enqueued_jobs { TestSupport.request_cancellation(order.id) }

      perform_enqueued_jobs { Payments::Api.request_capture(reference: order.reference) }

      assert_equal "cancelled", order.reload.state
      assert_equal "voided", Payments::TestSupport.payment(order.reference).state, "the hold was voided before the late capture could take it"
    end

    test "an order that has shipped cannot be cancelled" do
      order = place
      perform_due_jobs
      MarkShippedJob.perform_now(EventRail.publish(Fulfillment::Events::ShipmentDispatched.new(reference: order.reference, tracking_code: "TRK-1")).event)

      assert_raises(NotCancellable) { TestSupport.request_cancellation(order.id) }
    end

    test "a cancellation requested before Orders heard of the dispatch is refused by Fulfillment, and the order carries on" do
      order = place
      perform_due_jobs # captured and paid; the carrier's collection is scheduled for later
      perform_enqueued_jobs(only: ->(job) { job.fetch(:job).name == "Fulfillment::DispatchJob" }) # collected: Orders has not heard yet

      TestSupport.request_cancellation(order.id)
      perform_enqueued_jobs(only: CancelJob)
      perform_due_jobs # and now Orders hears of the dispatch

      record = order.reload
      assert record.cancellation_refused_at
      assert_equal "shipped", record.status
    end

    test "a refused cancellation replayed after the order was delivered and returned changes nothing" do
      order = place
      perform_due_jobs
      perform_enqueued_jobs(only: ->(job) { job.fetch(:job).name == "Fulfillment::DispatchJob" })
      TestSupport.request_cancellation(order.id)
      perform_enqueued_jobs(only: CancelJob)
      travel(2.hours) { perform_due_jobs } # the dispatch is heard and the parcel delivered
      TestSupport.request_return(order.id)

      assert_no_changes -> { order.reload.attributes } do
        CancelJob.perform_now(order.reload)
      end
      assert_equal "returning", order.reload.status
    end

    test "cancelling twice changes nothing and announces nothing further" do
      order = place
      perform_enqueued_jobs { TestSupport.request_cancellation(order.id) }

      published = record_publications { perform_enqueued_jobs { TestSupport.request_cancellation(order.id, reason: "again") } }

      assert_equal "customer", order.reload.cancel_reason
      assert_empty published
    end

    test "a cancellation requested while the queue is unavailable is carried out once it recovers" do
      order = place
      clear_enqueued_jobs
      refusing_enqueue { TestSupport.request_cancellation(order.id) }

      published = record_publications do
        relay_staged_jobs
        perform_due_jobs
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

    test "a cancellation and everything it causes share one flow, not the placement's" do
      placed = record_publications { @order = place }
      clear_enqueued_jobs

      published = record_publications { perform_enqueued_jobs { TestSupport.request_cancellation(@order.id) } }

      assert_equal 1, published.map(&:correlation_id).uniq.size
      assert_not_includes placed.map(&:correlation_id), published.first.correlation_id
    end
  end
end
