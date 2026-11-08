require "test_helper"

module Orders
  class ConfirmationTest < ActiveSupport::TestCase
    include Steps

    test "confirming holds the stock, authorizes the card, and asks for the capture" do
      order = place_and_confirm_order

      assert_equal "confirmed", order.state
      assert_equal 2, held("MUG")
      assert_equal :held, Payments::TestSupport.money_status(order.reference)
      assert_equal order.total_cents, Payments::TestSupport.money_amount(order.reference)
      assert_equal :capture, Payments::TestSupport.pending_request(order.reference)
    end

    test "an out-of-stock item cancels the order with the reason, and nothing stays held" do
      published = record_publications { @order = place_and_confirm_order(items: { "TEA" => 1, "MUG" => on_hand("MUG") + 1 }) }

      assert_equal "cancelled", @order.state
      assert_equal [ :out_of_stock, "out of stock: MUG" ], [ TestSupport.order(@order.id).cancel_cause, @order.cancel_reason ]
      assert_equal 0, held("TEA")
      assert_nil Payments::TestSupport.money_status(@order.reference)
      assert_equal %w[ orders.order_cancelled orders.order_placed ], published.map(&:event_type).sort
    end

    test "a cancellation completed while confirming was under way gets the stock back, even when the card is then declined" do
      Payments::TestSupport.provider_refuses(:authorize)
      order = checkout_order
      confirming = Order.find(order.id) # read as placed, as the confirmation's job did
      perform_enqueued_jobs(only: CancelJob) { TestSupport.request_cancellation(order.id) }

      confirming.confirm

      assert_equal "cancelled", order.reload.state
      assert_equal 0, held("MUG")
    end

    test "a declined card cancels the order and gives its stock back" do
      Payments::TestSupport.provider_refuses(:authorize)

      order = place_and_confirm_order

      assert_equal "cancelled", order.state
      assert_equal :payment_declined, TestSupport.order(order.id).cancel_cause
      assert_equal 0, held("MUG")
      assert_nil Payments::TestSupport.money_status(order.reference)
    end

    test "a payment provider that does not answer is retried until it does; no count of attempts gives up" do
      Payments::TestSupport.provider_times_out(:authorize, times: 3)

      order = place_and_confirm_order

      assert_equal "confirmed", order.state
    end

    test "confirming interrupted after the reservation reserves once when it runs again" do
      order = checkout_order
      failing(Payments::Api, :authorize) { perform_enqueued_jobs(only: ConfirmJob) }
      assert_equal "placed", order.reload.state

      perform_enqueued_jobs(only: ConfirmJob)

      assert_equal "confirmed", order.reload.state
      assert_equal 2, held("MUG")
    end

    test "confirming interrupted after the authorization is confirmed when it runs again" do
      order = checkout_order
      interrupting_after(Payments::Api, :authorize) { perform_enqueued_jobs(only: ConfirmJob) }
      assert_equal "placed", order.reload.state

      perform_enqueued_jobs(only: ConfirmJob)

      assert_equal "confirmed", order.reload.state
      assert_equal [ :held, :capture ], [ Payments::TestSupport.money_status(order.reference), Payments::TestSupport.pending_request(order.reference) ]
    end

    test "confirming interrupted after the order is confirmed asks for the capture when it runs again" do
      order = checkout_order
      failing(Payments::Api, :request_capture) { perform_enqueued_jobs(only: ConfirmJob) }
      assert_equal "confirmed", order.reload.state
      assert_nil Payments::TestSupport.pending_request(order.reference)

      perform_enqueued_jobs(only: ConfirmJob)

      assert_equal :capture, Payments::TestSupport.pending_request(order.reference)
    end

    test "the placement is announced once, in the transaction that records the order" do
      order = nil
      placed = record_publications { order = checkout_order }
      later = record_publications do
        failing(Payments::Api, :request_capture) { perform_enqueued_jobs(only: ConfirmJob) }
        perform_enqueued_jobs(only: ConfirmJob)
      end

      assert_equal [ "orders.order_placed" ], placed.map(&:event_type)
      assert_equal 2, placed.sole.event_version
      assert_not later.any? { |publication| publication.event_type == "orders.order_placed" }, "confirming, however often it runs, announces nothing again"
      assert_equal "confirmed", order.reload.state
    end

    test "a confirmation handed to the queue twice confirms the order once" do
      order = checkout_order
      # As if the first hand-over had crashed after enqueuing and before deleting its row.
      staged = enqueued_jobs.find { |job| job["job_class"] == ConfirmJob.name }.except(:job, :args, :queue, :priority, :at)
      Platform::StagedJob.create!(job_id: staged["job_id"], job_class: ConfirmJob.name, payload: staged, created_at: 1.minute.ago)
      Platform::StagedJobRelayJob.perform_now
      assert_equal 2, enqueued_jobs.count { |job| job["job_class"] == ConfirmJob.name }

      perform_enqueued_jobs(only: ConfirmJob)

      assert_equal "confirmed", order.reload.state
      assert_equal 2, held("MUG"), "the stock is held once"
    end
  end
end
