require "test_helper"

module Orders
  class PaymentAndShippingTest < ActiveSupport::TestCase
    include Steps

    test "a paid order is shipped what it holds, then delivered, and announces each" do
      order = place_and_confirm_order
      published = record_publications do
        payments_answer
        assert_equal :requested, Fulfillment::TestSupport.shipment_status(order.reference)
        assert_equal order.line_items.to_h { |line| [ line.sku, line.quantity ] }, Fulfillment::TestSupport.shipment_items(order.reference)
        assert_difference(-> { on_hand("MUG") }, -2, "the stock leaves with the parcel") { carrier_collects }
        carrier_delivers
      end

      assert_equal "delivered", order.reload.status
      assert_equal order.total_cents, Payments::TestSupport.money_amount(order.reference), "the card was held for the order's total"
      assert_equal %w[ orders.order_delivered orders.order_shipped ], published.map(&:event_type).select { |type| type.start_with?("orders.") }.sort
      shipped = published.find { |publication| publication.event_type == "orders.order_shipped" }
      assert_equal published.find { |publication| publication.event_type == "fulfillment.shipment_dispatched" }.payload[:tracking_code], shipped.payload[:tracking_code]
    end

    test "an order is paid for only once confirmed" do
      order = checkout_order
      clear_enqueued_jobs # placed, its confirmation not run

      assert_nothing_raised do
        failing(Payments::Api, :request_capture, "an unconfirmed order asked to be paid") { order.request_payment }
      end
    end

    test "an order is shipped only once paid" do
      order = place_and_confirm_order
      clear_enqueued_jobs # confirmed, its capture not run

      order.request_shipment

      assert_nil Fulfillment::TestSupport.shipment_status(order.reference)
    end

    test "no shipment is requested before the payment is captured" do
      order = place_and_confirm_order

      assert_nil Fulfillment::TestSupport.shipment_status(order.reference)
    end

    test "a refused capture cancels the order, says why, and gives back what it holds" do
      Payments::TestSupport.provider_refuses(:capture)
      order = place_and_confirm_order

      assert_difference(-> { available("MUG") }, +2) do
        payments_answer
        perform_enqueued_jobs(only: CancelJob)
      end

      assert_equal :payment_refused, TestSupport.order(order.id).cancel_cause
      assert_equal :cancelled, Fulfillment::TestSupport.shipment_status(order.reference), "nothing was asked of the carrier, and nothing can be now"
    end

    test "a redelivered capture does not pay or ship the order twice" do
      place_and_confirm_order
      payments_answer

      assert_redelivery_changes_nothing(MarkPaidJob)
      assert_equal :requested, Fulfillment::TestSupport.shipment_status(Order.sole.reference)
    end

    test "a redelivered dispatch does not ship the stock twice" do
      place_and_confirm_order
      payments_answer
      carrier_collects

      assert_no_difference(-> { on_hand("MUG") }) { assert_redelivery_changes_nothing(MarkShippedJob) }
    end

    test "a redelivered delivery does not deliver twice" do
      place_and_confirm_order
      payments_answer
      carrier_collects
      carrier_delivers

      assert_redelivery_changes_nothing(MarkDeliveredJob)
    end

    test "a dispatch recorded before the stock could be shipped ships it on retry" do
      order = place_and_confirm_order
      payments_answer
      Fulfillment::TestSupport.carrier_collects_parcels
      failing(Catalog::Api, :ship, "warehouse system down") do
        assert_no_difference(-> { on_hand("MUG") }) { hear_announcements } # the order is shipped; shipping the stock failed
      end
      assert_equal "shipped", order.reload.status

      assert_difference(-> { on_hand("MUG") }, -2) { perform_enqueued_jobs(only: MarkShippedJob) }
      assert_equal on_hand("MUG"), available("MUG"), "nothing is held any more"
    end

    test "a delivery heard before its dispatch waits for it and is not lost" do
      order = place_and_confirm_order
      payments_answer
      Fulfillment::TestSupport.carrier_collects_parcels
      Fulfillment::TestSupport.carrier_delivers_parcels

      published = record_publications do
        hear_announcements(only: ->(job_class) { job_class == MarkDeliveredJob }) # too early: retried later
        assert_equal "paid", order.reload.status
        hear_announcements
      end

      assert_equal "delivered", order.reload.status
      assert_equal %w[ orders.order_delivered orders.order_shipped ], published.map(&:event_type).sort
    end

    private
      # Delivers again the event the subscriber last heard; the redelivery must change nothing and
      # stage nothing.
      def assert_redelivery_changes_nothing(subscriber)
        state = -> { Order.sole.attributes.except("updated_at") }
        before = state.call

        again = record_publications { redeliver(subscriber) }

        assert_equal before, state.call
        assert_empty again, "the first delivery staged its event with the change; a redelivery stages nothing"
      end
  end
end
