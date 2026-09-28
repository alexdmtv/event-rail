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

    test "a cancellation is recorded at once and carried out in a job" do
      order = place
      clear_enqueued_jobs # its capture has not run

      Api.request_cancellation(order.id)
      assert_equal [ "confirmed", "customer" ], [ order_record(order).state, order_record(order).cancel_reason ]
      assert_enqueued_jobs 1, only: CancelJob

      perform_due_jobs
      assert_equal "cancelled", order_record(order).state
      assert_equal 10, available("MUG")
      assert_equal "voided", Payments::Api.payment(order.reference).state
    end

    test "cancelling after capture, before dispatch, releases the stock and refunds the payment" do
      order = place
      perform_due_jobs # captured and paid; the carrier has not collected the parcel

      perform_enqueued_jobs { Api.request_cancellation(order.id) }

      assert_equal "cancelled", order_record(order).state
      assert_equal 10, available("MUG")
      assert_equal "refunded", Payments::Api.payment(order.reference).state
    end

    test "a capture that lands after the cancellation is refunded" do
      order = place
      perform_enqueued_jobs { Api.request_cancellation(order.id) }

      perform_enqueued_jobs { Payments::Api.request_capture(reference: order.reference) }

      assert_equal "cancelled", order_record(order).state
      assert_equal "voided", Payments::Api.payment(order.reference).state, "the hold was voided before the late capture could take it"
    end

    test "an order that has shipped cannot be cancelled" do
      order = place
      perform_due_jobs
      MarkShippedJob.perform_now(EventRail.publish(Fulfillment::Events::ShipmentDispatched.new(reference: order.reference, tracking_code: "TRK-1")).event)

      assert_raises(NotCancellable) { Api.request_cancellation(order.id) }
    end

    test "a cancellation requested before Orders heard of the dispatch is refused by Fulfillment, and the order carries on" do
      order = place
      perform_due_jobs # captured and paid; the carrier's collection is scheduled for later
      perform_enqueued_jobs(only: ->(job) { job.fetch(:job).name == "Fulfillment::DispatchJob" }) # collected: Orders has not heard yet

      Api.request_cancellation(order.id)
      perform_enqueued_jobs(only: CancelJob)
      perform_due_jobs # and now Orders hears of the dispatch

      record = order_record(order)
      assert record.cancellation_refused_at
      assert_equal "shipped", record.status
    end

    test "cancelling twice changes nothing and announces nothing further" do
      order = place
      perform_enqueued_jobs { Api.request_cancellation(order.id) }

      published = record_publications { perform_enqueued_jobs { Api.request_cancellation(order.id, reason: "again") } }

      assert_equal "customer", order_record(order).cancel_reason
      assert_empty published
    end

    test "a cancellation requested while the queue is unavailable is carried out once it recovers" do
      order = place
      clear_enqueued_jobs
      refusing_enqueue { Api.request_cancellation(order.id) }

      published = record_publications do
        relay_staged_jobs
        perform_due_jobs
      end

      assert_equal "cancelled", order_record(order).state
      assert_includes published.map(&:event_type), "orders.order_cancelled"
    end

    test "a cancellation interrupted after its announcement announces again under the same identity" do
      order = place
      clear_enqueued_jobs
      Api.request_cancellation(order.id)
      first = record_publications { failing(Payments::Api, :request_release) { perform_enqueued_jobs(only: CancelJob) } }
      again = record_publications { perform_enqueued_jobs(only: CancelJob) }

      cancelled = (first + again).select { |publication| publication.event_type == "orders.order_cancelled" }
      assert_equal 1, cancelled.size, "the first run failed before announcing"
      assert_equal 10, available("MUG")
    end

    test "a cancellation joins the order's flow" do
      order = place
      clear_enqueued_jobs

      published = record_publications { perform_enqueued_jobs { Api.request_cancellation(order.id) } }

      assert_equal [ order.correlation_id ], published.map(&:correlation_id).uniq
    end
  end
end
