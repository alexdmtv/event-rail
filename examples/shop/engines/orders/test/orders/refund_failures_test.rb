require "test_helper"

module Orders
  # Payments answers a release with the order's reference only; each requester's subscriber
  # looks for its own record, and leaves everyone else's alone.
  class RefundFailuresTest < ActiveSupport::TestCase
    include Steps

    test "a return's refused refund is recorded on the return, once, and the cancellation's subscriber ignores it" do
      @order = place
      pay(@order)
      ship(@order)
      deliver(@order)
      perform_enqueued_jobs(only: RequestReturnPickupJob) { TestSupport.request_return(@order.id) }
      bring_back(@order)
      refuse_refund(@order)
      assert_equal "refund_failed", @order.reload.return.state

      assert_no_changes -> { [ @order.reload.attributes, @order.return.reload.attributes ] } do
        RecordReturnRefundFailureJob.perform_now(refusal(@order.reference, "again"))
        RecordCancellationRefundFailureJob.perform_now(refusal(@order.reference, "again"))
      end
    end

    test "a cancellation's refused refund is ignored by the return's subscriber" do
      order = place
      pay(order)
      perform_enqueued_jobs(only: CancelJob) { TestSupport.request_cancellation(order.id) }
      refuse_refund(order)
      assert order.reload.refund_refused_at

      assert_no_changes -> { order.reload.attributes } do
        RecordReturnRefundFailureJob.perform_now(refusal(order.reference, "again"))
      end
      assert_nil order.return
    end

    test "a refusal for an unknown reference is ignored" do
      assert_nothing_raised do
        RecordReturnRefundFailureJob.perform_now(refusal("nobody", "stray"))
        RecordCancellationRefundFailureJob.perform_now(refusal("nobody", "stray"))
      end
    end

    private
      def refusal(reference, reason) = EventRail.publish(Payments::Events::RefundFailed.new(reference:, reason:)).event
  end
end
