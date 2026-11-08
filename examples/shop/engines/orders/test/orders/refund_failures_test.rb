require "test_helper"

module Orders
  # Payments answers a release with the order's reference only; each requester's subscriber
  # looks for its own record, and leaves everyone else's alone.
  class RefundFailuresTest < ActiveSupport::TestCase
    include Steps

    test "a return's refused refund is recorded on the return, once, and the cancellation's subscriber ignores it" do
      Payments::TestSupport.provider_refuses(:refund)
      order = place_and_confirm_order
      payments_answer
      carrier_collects
      carrier_delivers
      perform_enqueued_jobs(only: RequestReturnPickupJob) { TestSupport.request_return(order.id) }
      carrier_brings_back
      payments_answer
      assert_equal "refund_failed", order.reload.return.state

      assert_no_changes -> { [ order.reload.attributes, order.return.reload.attributes ] } do
        redeliver(RecordReturnRefundFailureJob)
        redeliver(RecordCancellationRefundFailureJob)
      end
    end

    test "a cancellation's refused refund is ignored by the return's subscriber" do
      Payments::TestSupport.provider_refuses(:refund)
      order = place_and_confirm_order
      payments_answer
      perform_enqueued_jobs(only: CancelJob) { TestSupport.request_cancellation(order.id) }
      payments_answer
      assert order.reload.refund_refused_at

      assert_no_changes(-> { order.reload.attributes }) { redeliver(RecordReturnRefundFailureJob) }
      assert_nil order.return
    end

    test "a refusal for an unknown reference is ignored" do
      stray = EventRail.publish(Payments::Events::RefundFailed.new(reference: "nobody", reason: "stray")).event

      perform_once(RecordReturnRefundFailureJob, stray)
      perform_once(RecordCancellationRefundFailureJob, stray)
    end
  end
end
