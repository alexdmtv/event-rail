require "test_helper"

module Orders
  class PaymentAndShippingTest < ActiveSupport::TestCase
    include Steps

    test "a paid order is shipped, then delivered, and announces each" do
      order = place
      published = record_publications do
        pay(order)
        assert_equal :requested, Fulfillment::TestSupport.shipment_status(order.reference)
        ship(order)
        deliver(order)
      end

      assert_equal "delivered", order.reload.status
      assert_equal %w[ orders.order_delivered orders.order_shipped ], published.map(&:event_type).select { |type| type.start_with?("orders.") }.sort
      assert_equal 8, on_hand("MUG"), "the stock left with the parcel"
    end

    test "an order is paid for only once confirmed" do
      order = checkout
      clear_enqueued_jobs # placed, its confirmation not run

      assert_nothing_raised do
        failing(Payments::Api, :request_capture, "an unconfirmed order asked to be paid") { order.request_payment }
      end
    end

    test "an order is shipped only once paid" do
      order = place
      clear_enqueued_jobs # confirmed, its capture not run

      order.request_shipment

      assert_nil Fulfillment::TestSupport.shipment_status(order.reference)
    end

    test "no shipment is requested before the payment is captured" do
      order = place

      assert_nil Fulfillment::TestSupport.shipment_status(order.reference)
    end

    test "a redelivered capture does not pay or ship the order twice" do
      order = place
      event = Payments::Events::PaymentCaptured.new(reference: order.reference, amount_cents: order.total_cents, currency: "EUR")

      assert_redelivery_changes_nothing(MarkPaidJob, event)
      assert_equal :requested, Fulfillment::TestSupport.shipment_status(order.reference)
    end

    test "a redelivered dispatch does not ship the stock twice" do
      order = place
      pay(order)
      event = Fulfillment::Events::ShipmentDispatched.new(reference: order.reference, tracking_code: "TRK-1")

      assert_redelivery_changes_nothing(MarkShippedJob, event)
      assert_equal 8, on_hand("MUG")
    end

    test "a redelivered delivery does not deliver twice" do
      order = place
      pay(order)
      ship(order)
      event = Fulfillment::Events::ShipmentDelivered.new(reference: order.reference)

      assert_redelivery_changes_nothing(MarkDeliveredJob, event)
    end

    test "a dispatch recorded before the stock could be shipped ships it on retry" do
      order = place
      pay(order)
      dispatched = EventRail.publish(Fulfillment::Events::ShipmentDispatched.new(reference: order.reference, tracking_code: "TRK-1")).event
      clear_enqueued_jobs
      failing(Catalog::Api, :ship, "warehouse system down") do
        MarkShippedJob.perform_now(dispatched) # the order is shipped; shipping the stock failed
      end
      assert_equal [ "shipped", 10 ], [ order.reload.status, on_hand("MUG") ]

      perform_enqueued_jobs(only: MarkShippedJob)

      assert_equal 8, on_hand("MUG")
      assert_equal 8, available("MUG")
    end

    test "a delivery heard before its dispatch waits for it and is not lost" do
      order = place
      pay(order)
      delivered = EventRail.publish(Fulfillment::Events::ShipmentDelivered.new(reference: order.reference)).event
      dispatched = EventRail.publish(Fulfillment::Events::ShipmentDispatched.new(reference: order.reference, tracking_code: "TRK-1")).event
      clear_enqueued_jobs

      published = record_publications do
        MarkDeliveredJob.perform_now(delivered) # too early: retried later
        assert_equal "paid", order.reload.status
        MarkShippedJob.perform_now(dispatched)
        perform_enqueued_jobs(only: MarkDeliveredJob)
      end

      assert_equal "delivered", order.reload.status
      assert_equal %w[ orders.order_delivered orders.order_shipped ], published.map(&:event_type).sort
      assert_equal 8, on_hand("MUG")
    end

    private
      # Delivers the event twice; the second delivery must change nothing and stage nothing.
      def assert_redelivery_changes_nothing(subscriber, event)
        stamped = EventRail.publish(event).event
        clear_enqueued_jobs

        subscriber.perform_now(stamped)
        state_after_first = Orders::Order.sole.attributes.except("updated_at")
        second = record_publications { subscriber.perform_now(stamped) }

        assert_equal state_after_first, Orders::Order.sole.attributes.except("updated_at")
        assert_empty second, "the first delivery staged its event with the change; a redelivery stages nothing"
      end
  end
end
