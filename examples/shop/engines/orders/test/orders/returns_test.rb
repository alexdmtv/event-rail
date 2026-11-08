require "test_helper"

module Orders
  class ReturnsTest < ActiveSupport::TestCase
    include Steps

    setup do
      @order = place
      pay(@order)
      ship(@order)
      deliver(@order)
    end

    test "a return within 14 days awaits the parcel" do
      perform_enqueued_jobs(only: RequestReturnPickupJob) { TestSupport.request_return(@order.id) }

      assert_equal "returning", @order.reload.status
      assert_equal :expected, Fulfillment::TestSupport.parcel_return_status(@order.reference)
    end

    test "a return requested while the queue is unavailable reaches the carrier once it recovers" do
      refusing_enqueue { TestSupport.request_return(@order.id) }
      assert_nil Fulfillment::TestSupport.parcel_return_status(@order.reference)

      relay_staged_jobs
      perform_enqueued_jobs(only: RequestReturnPickupJob)

      assert_equal :expected, Fulfillment::TestSupport.parcel_return_status(@order.reference)
    end

    test "a return requested again after the 14 days returns the return already under way" do
      TestSupport.request_return(@order.id)

      travel 15.days do
        assert_equal :returning, TestSupport.request_return(@order.id).status
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

    test "the returned parcel is restocked and its money asked back, and the order is refunded once the money is back" do
      perform_enqueued_jobs(only: RequestReturnPickupJob) { TestSupport.request_return(@order.id) }

      bring_back(@order)
      assert_equal 10, on_hand("MUG")
      assert Payments::TestSupport.release_requested?(@order.reference)
      assert_equal "returning", @order.reload.status

      published = record_publications { refund(@order) }
      assert_equal "refunded", @order.reload.status
      assert_includes published.map(&:event_type), "orders.order_refunded"
    end

    test "a refused refund sets the order aside for attention" do
      perform_enqueued_jobs(only: RequestReturnPickupJob) { TestSupport.request_return(@order.id) }
      bring_back(@order)

      refuse_refund(@order)

      record = @order.reload
      assert_equal [ "needs_attention", "refund refused" ], [ record.status, record.return.failure_reason ]
    end
  end
end
