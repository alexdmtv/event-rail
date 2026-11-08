require "test_helper"

module Orders
  class ReturnsTest < ActiveSupport::TestCase
    include Steps

    setup do
      @order = place_and_confirm_order
      payments_answer
      carrier_collects
      carrier_delivers
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
      order = checkout_order

      assert_raises(NotReturnable) { TestSupport.request_return(order.id) }
    end

    test "the returned parcel is restocked and refunded, and the order refunded once the money is back" do
      perform_enqueued_jobs(only: RequestReturnPickupJob) { TestSupport.request_return(@order.id) }

      assert_difference(-> { on_hand("MUG") }, +2) { carrier_brings_back }
      assert_equal "returning", @order.reload.status

      published = record_publications { payments_answer }
      assert_equal "refunded", @order.reload.status
      assert_equal :refunded, Payments::TestSupport.money_status(@order.reference)
      assert_includes published.map(&:event_type), "orders.order_refunded"
    end

    test "a refused refund sets the order aside for attention" do
      Payments::TestSupport.provider_refuses(:refund)
      perform_enqueued_jobs(only: RequestReturnPickupJob) { TestSupport.request_return(@order.id) }
      carrier_brings_back

      payments_answer

      record = @order.reload
      assert_equal "needs_attention", record.status
      assert record.return.failure_reason.present?, "the refusal's reason is kept for a person"
    end

    test "a redelivered return or refund changes nothing" do
      perform_enqueued_jobs(only: RequestReturnPickupJob) { TestSupport.request_return(@order.id) }
      carrier_brings_back
      payments_answer
      state = -> { [ @order.reload.attributes, @order.return.reload.attributes ] }

      assert_no_changes(state) do
        assert_empty record_publications { redeliver(ReceiveReturnJob); redeliver(CompleteRefundJob) }
      end
    end
  end
end
