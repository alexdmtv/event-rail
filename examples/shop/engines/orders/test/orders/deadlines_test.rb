require "test_helper"

module Orders
  # The sweep runs from the recurring schedule, by its key, as Solid Queue's scheduler would.
  class DeadlinesTest < ActiveSupport::TestCase
    include Steps

    test "an order not confirmed within two minutes is cancelled, and what confirming took is given back" do
      order = checkout_order
      assert_difference(-> { available("MUG") }, -2) do
        failing(Payments::Api, :authorize) { perform_enqueued_jobs(only: ConfirmJob) } # reserved, then failed
      end
      clear_enqueued_jobs # as if the confirmation were stuck

      assert_difference(-> { available("MUG") }, +2) { travel(3.minutes) { sweep } }

      assert_equal [ :cancelled, :not_confirmed_in_time ], TestSupport.order(order.id).then { |snapshot| [ snapshot.state, snapshot.cancel_cause ] }
    end

    test "a confirmed order not paid within thirty minutes is cancelled, and its card's hold given back" do
      order = place_and_confirm_order
      clear_enqueued_jobs # its capture never ran

      travel(31.minutes) { sweep }

      assert_equal [ :cancelled, :not_paid_in_time ], TestSupport.order(order.id).then { |snapshot| [ snapshot.state, snapshot.cancel_cause ] }
      assert Payments::TestSupport.release_requested?(order.reference)
    end

    test "an order paid in time is left alone" do
      order = place_and_confirm_order
      payments_answer

      travel(31.minutes) { sweep }

      assert_equal "paid", order.reload.status
      assert_nil order.cancellation_requested_at
    end

    test "a deadline passing while the confirmation is running leaves the order cancelled and gives back what the run took" do
      order = checkout_order
      # The sweep runs while confirming is between the reservation and the authorization.
      in_the_middle = -> { travel(3.minutes) { sweep } }

      assert_no_difference(-> { available("MUG") }) do
        before_calling(Payments::Api, :authorize, in_the_middle) { perform_enqueued_jobs(only: ConfirmJob) }
        perform_enqueued_jobs(only: [ ConfirmJob, CancelJob ])
      end

      assert_equal [ :cancelled, :not_confirmed_in_time ], TestSupport.order(order.id).then { |snapshot| [ snapshot.state, snapshot.cancel_cause ] }
      assert Payments::TestSupport.release_requested?(order.reference), "the card's hold is to be given back"
    end

    test "a sweep's cancellations share the sweep's run as their flow" do
      2.times { place_and_confirm_order }
      clear_enqueued_jobs

      published = travel(31.minutes) { record_publications { sweep } }

      assert_equal 2, published.count { |publication| publication.event_type == "orders.order_cancelled" }
      assert_equal 1, published.map(&:correlation_id).uniq.size
      assert published.first.correlation_id
    end

    private
      def sweep = perform_enqueued_jobs(only: [ DeadlineSweepJob, CancelJob ]) { enqueue_scheduled(:enforce_order_deadlines) }
  end
end
