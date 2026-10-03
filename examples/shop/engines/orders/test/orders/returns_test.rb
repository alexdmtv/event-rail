require "test_helper"

module Orders
  class ReturnsTest < ActiveSupport::TestCase
    include ShopHelpers

    setup do
      stock_shelves
      instant_carrier
      perform_enqueued_jobs { @order = checkout }
    end

    test "a return within 14 days awaits the parcel" do
      slow_carrier

      perform_enqueued_jobs(only: RequestReturnPickupJob) { TestSupport.request_return(@order.id) }

      assert_equal "returning", @order.reload.status
      assert_equal "expected", Fulfillment::TestSupport.parcel_return(@order.reference).state
    end

    test "a return requested while the queue is unavailable reaches the carrier once it recovers" do
      slow_carrier
      refusing_enqueue { TestSupport.request_return(@order.id) }
      assert_nil Fulfillment::TestSupport.parcel_return(@order.reference)

      relay_staged_jobs
      perform_enqueued_jobs(only: RequestReturnPickupJob)

      assert_equal "expected", Fulfillment::TestSupport.parcel_return(@order.reference).state
    end

    test "a return requested again after the 14 days returns the return already under way" do
      slow_carrier
      TestSupport.request_return(@order.id)

      travel 15.days do
        assert_equal "returning", TestSupport.request_return(@order.id).status
      end
    end

    test "a return after 14 days is refused" do
      travel 15.days do
        assert_raises(NotReturnable) { TestSupport.request_return(@order.id) }
      end
    end

    test "an order that was not delivered cannot be returned" do
      order = checkout

      assert_raises(NotReturnable) { TestSupport.request_return(order.id) }
    end

    test "the returned parcel is restocked, refunded, and the order refunded" do
      published = record_publications { perform_enqueued_jobs { TestSupport.request_return(@order.id) } }

      assert_equal "refunded", @order.reload.status
      assert_equal 10, on_hand("MUG")
      assert_equal "refunded", Payments::TestSupport.payment(@order.reference).state
      assert_includes published.map(&:event_type), "orders.order_refunded"
    end

    test "a refused refund sets the order aside for attention" do
      Payments::Gateway.adapter = ScriptedGateway.new(refund: [ :refuse ])

      perform_enqueued_jobs { TestSupport.request_return(@order.id) }

      record = @order.reload
      assert_equal "needs_attention", record.status
      assert_match(/refund refused/, record.return.failure_reason)
    end
  end
end
