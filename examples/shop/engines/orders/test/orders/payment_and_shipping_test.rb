require "test_helper"
require_relative "../support/order_records"

module Orders
  class PaymentAndShippingTest < ActiveSupport::TestCase
    include ShopHelpers
    include OrderRecords

    setup { stock_shelves }

    test "a captured order is paid, then shipped, then delivered" do
      order = nil
      published = record_publications { perform_enqueued_jobs { order = checkout } }

      assert_equal "delivered", order_record(order).state
      # EventRail promises no ordering, and inline test jobs finish nested publications first.
      assert_equal %w[ fulfillment.shipment_delivered fulfillment.shipment_dispatched orders.order_delivered orders.order_placed
        orders.order_shipped payments.payment_captured ], published.map(&:event_type).sort
      assert_equal 2, published.find { |publication| publication.event_type == "orders.order_placed" }.event_version
      assert_equal 8, on_hand("MUG")
    end

    test "temporary capture failures are retried and the order is paid with a single capture" do
      Payments::Gateway.adapter = gateway = ScriptedGateway.new(capture: [ :timeout, :timeout ])
      order = nil

      perform_enqueued_jobs { order = checkout }

      assert_equal 3, gateway.calls[:capture]
      assert_equal "delivered", order_record(order).state
    end

    test "a refused capture cancels the order and nothing ships" do
      Payments::Gateway.adapter = ScriptedGateway.new(capture: [ :refuse ])
      order = nil

      published = record_publications { perform_enqueued_jobs { order = checkout } }

      record = order_record(order)
      assert_equal "cancelled", record.state
      assert_match(/payment refused/, record.cancel_reason)
      assert_equal 10, available("MUG")
      assert_nil Fulfillment::Api.shipment(order.reference)
      assert_includes published.map(&:event_type), "orders.order_cancelled"
    end

    test "no shipment is requested before the payment is captured" do
      slow_carrier
      order = checkout
      perform_enqueued_jobs(only: FollowUpJob)

      assert_nil Fulfillment::Api.shipment(order.reference)
    end

    test "a redelivered capture does not pay or ship the order twice" do
      slow_carrier
      order = checkout
      perform_due_jobs
      event = Payments::Events::PaymentCaptured.new(reference: order.reference, amount_cents: order.total_cents, currency: "EUR")

      assert_redelivery_changes_nothing(MarkPaidJob, event)
      assert_equal "requested", Fulfillment::Api.shipment(order.reference).state
    end

    test "a redelivered dispatch does not ship the stock twice" do
      slow_carrier
      order = checkout
      perform_due_jobs
      event = Fulfillment::Events::ShipmentDispatched.new(reference: order.reference, tracking_code: "TRK-1")

      assert_redelivery_changes_nothing(MarkShippedJob, event)
      assert_equal 8, on_hand("MUG")
    end

    test "a redelivered delivery does not deliver twice" do
      slow_carrier
      order = checkout
      perform_due_jobs
      MarkShippedJob.perform_now(EventRail.publish(Fulfillment::Events::ShipmentDispatched.new(reference: order.reference, tracking_code: "TRK-1")).event)
      event = Fulfillment::Events::ShipmentDelivered.new(reference: order.reference)

      assert_redelivery_changes_nothing(MarkDeliveredJob, event)
    end

    private
      # Delivers the same event to the subscriber twice. The second delivery must leave the
      # order as the first left it, and anything it republishes must carry the identity the
      # first delivery's publication had.
      def assert_redelivery_changes_nothing(subscriber, event)
        stamped = EventRail.publish(event).event
        clear_enqueued_jobs

        first = record_publications { subscriber.perform_now(stamped) }
        state_after_first = Orders::Order.sole.attributes.except("updated_at")
        second = record_publications { subscriber.perform_now(stamped) }

        assert_equal state_after_first, Orders::Order.sole.attributes.except("updated_at")
        assert_equal first.map(&:event_id), second.map(&:event_id)
      end
  end
end
