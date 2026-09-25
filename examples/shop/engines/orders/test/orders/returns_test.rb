require "test_helper"
require_relative "../support/order_records"

module Orders
  class ReturnsTest < ActiveSupport::TestCase
    include ShopHelpers
    include OrderRecords

    setup do
      stock_shelves
      Platform::FaultSettings.current.update!(carrier_delay_seconds: 0)
      perform_enqueued_jobs { @order = checkout }
    end

    test "a return within 14 days awaits the parcel" do
      slow_carrier

      Api.request_return(@order.id)

      assert_equal "awaiting_return", order_record(@order).state
      assert_equal "expected", Fulfillment::Api.parcel_return(@order.reference).state
    end

    test "a return after 14 days is refused" do
      travel 15.days do
        assert_raises(Api::NotReturnable) { Api.request_return(@order.id) }
      end
    end

    test "an order that was not delivered cannot be returned" do
      order = checkout(key: "key-2")

      assert_raises(Api::NotReturnable) { Api.request_return(order.id) }
    end

    test "the returned parcel is restocked, refunded, and the order refunded" do
      published = record_publications { perform_enqueued_jobs { Api.request_return(@order.id) } }

      assert_equal "refunded", order_record(@order).state
      assert_equal 10, on_hand("MUG")
      assert_equal "refunded", Payments::Api.payment(@order.reference).state
      assert_includes published.map(&:event_type), "orders.order_refunded"
    end

    test "a refused refund sets the order aside for attention" do
      Payments::Gateway.adapter = ScriptedGateway.new(refund: [ :refuse ])

      perform_enqueued_jobs { Api.request_return(@order.id) }

      record = order_record(@order)
      assert_equal "needs_attention", record.state
      assert_match(/refund refused/, record.attention_reason)
    end
  end
end
