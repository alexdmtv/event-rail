require "test_helper"

module Orders
  class CancellationTest < ActiveSupport::TestCase
    include Steps

    test "a cancellation is recorded at once and carried out in a job" do
      order = place_and_confirm_order
      clear_enqueued_jobs # its capture has not run

      assert_difference -> { available("MUG") }, +2 do
        TestSupport.request_cancellation(order.id)
        assert_equal [ "confirmed", "customer" ], [ order.reload.state, order.cancel_reason ]
        assert_enqueued_jobs 1, only: CancelJob

        perform_enqueued_jobs(only: CancelJob)
      end
      assert_equal "cancelled", order.reload.state
      assert Payments::TestSupport.release_requested?(order.reference), "the card's hold is to be given back"
    end

    test "cancelling a paid order before dispatch releases the stock, calls off the shipment and has the money refunded" do
      order = place_and_confirm_order
      payments_answer # captured and paid
      assert_equal :requested, Fulfillment::TestSupport.shipment_status(order.reference)

      assert_difference -> { available("MUG") }, +2 do
        perform_enqueued_jobs(only: CancelJob) { TestSupport.request_cancellation(order.id) }
      end
      published = record_publications { payments_answer }

      assert_equal [ "cancelled", "cancelled" ], [ order.reload.state, order.status ]
      assert_equal :cancelled, Fulfillment::TestSupport.shipment_status(order.reference)
      assert_equal :refunded, Payments::TestSupport.money_status(order.reference)
      assert_not_includes published.map(&:event_type), "orders.order_refunded", "a cancellation's refund is not a return's"
    end

    test "a cancellation's refused refund sets the order aside for a person, once" do
      Payments::TestSupport.provider_refuses(:refund)
      order = place_and_confirm_order
      payments_answer
      perform_enqueued_jobs(only: CancelJob) { TestSupport.request_cancellation(order.id) }

      published = record_publications { payments_answer }

      assert_equal "needs_attention", order.reload.status
      assert order.refund_failure_reason.present?, "the refusal's reason is kept for a person"
      assert_not_includes published.map(&:event_type), "orders.order_refunded"
      assert_no_changes(-> { order.reload.attributes }) { redeliver(RecordCancellationRefundFailureJob) }
    end

    test "a refused refund for an order neither cancelled nor returning changes nothing" do
      order = place_and_confirm_order
      payments_answer
      stray = EventRail.publish(Payments::Events::RefundFailed.new(reference: order.reference, reason: "stray")).event

      assert_no_changes(-> { order.reload.attributes }) { perform_once(RecordCancellationRefundFailureJob, stray) }
    end

    test "an order that has shipped cannot be cancelled" do
      order = place_and_confirm_order
      payments_answer
      carrier_collects

      assert_raises(NotCancellable) { TestSupport.request_cancellation(order.id) }
    end

    test "a cancellation requested once the parcel left, before Orders heard, is refused, and the order carries on" do
      order = place_and_confirm_order
      payments_answer
      Fulfillment::TestSupport.carrier_collects_parcels # Orders has not heard yet

      perform_enqueued_jobs(only: CancelJob) { TestSupport.request_cancellation(order.id) }

      assert order.reload.cancellation_refused_at, "Fulfillment refused: the parcel had left"
      assert_equal "paid", order.status
      hear_announcements
      assert_equal "shipped", order.reload.status
    end

    test "a refused cancellation replayed after the order was delivered and returned changes nothing" do
      order = place_and_confirm_order
      payments_answer
      Fulfillment::TestSupport.carrier_collects_parcels
      perform_enqueued_jobs(only: CancelJob) { TestSupport.request_cancellation(order.id) }
      hear_announcements
      carrier_delivers
      TestSupport.request_return(order.id)

      assert_no_changes -> { order.reload.attributes } do
        CancelJob.perform_now(order.reload)
      end
      assert_equal "returning", order.reload.status
    end

    test "asking again before the cancellation ran changes nothing" do
      order = place_and_confirm_order
      clear_enqueued_jobs

      TestSupport.request_cancellation(order.id)
      TestSupport.request_cancellation(order.id, reason: "again")

      assert_enqueued_jobs 1, only: CancelJob
      assert_equal "customer", order.reload.cancel_reason
    end

    test "cancelling twice changes nothing and announces nothing further" do
      order = place_and_confirm_order
      perform_enqueued_jobs(only: CancelJob) { TestSupport.request_cancellation(order.id) }

      published = record_publications { perform_enqueued_jobs(only: CancelJob) { TestSupport.request_cancellation(order.id, reason: "again") } }

      assert_equal "customer", order.reload.cancel_reason
      assert_empty published
    end

    test "a cancellation requested while the queue is unavailable is carried out once it recovers" do
      order = place_and_confirm_order
      clear_enqueued_jobs
      refusing_enqueue { TestSupport.request_cancellation(order.id) }

      published = record_publications do
        relay_staged_jobs
        perform_enqueued_jobs(only: CancelJob)
      end

      assert_equal "cancelled", order.reload.state
      assert_includes published.map(&:event_type), "orders.order_cancelled"
    end

    test "a cancellation interrupted after its announcement gives back what it holds when it runs again, announcing nothing more" do
      order = place_and_confirm_order
      clear_enqueued_jobs
      TestSupport.request_cancellation(order.id)
      first = record_publications { failing(Payments::Api, :request_release) { perform_enqueued_jobs(only: CancelJob) } }
      again = record_publications { perform_enqueued_jobs(only: CancelJob) }

      assert_equal [ "orders.order_cancelled" ], first.map(&:event_type), "the first run announced before it failed"
      assert_empty again
      assert Payments::TestSupport.release_requested?(order.reference), "the run again asked for the money back"
      assert_equal Catalog::TestSupport.on_hand("MUG"), available("MUG"), "nothing is held any more"
    end
  end
end
