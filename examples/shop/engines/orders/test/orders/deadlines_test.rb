require "test_helper"

module Orders
  class DeadlinesTest < ActiveSupport::TestCase
    include Steps

    setup { Fulfillment::TestSupport.slow_carrier }

    test "an order not confirmed within two minutes is cancelled, and what confirming took is given back" do
      order = checkout
      failing(Payments::Api, :authorize) { perform_enqueued_jobs(only: ConfirmJob) } # reserved, then failed
      clear_enqueued_jobs # as if the confirmation were stuck
      assert_equal 8, available("MUG")

      travel(3.minutes) { perform_enqueued_jobs { DeadlineSweepJob.perform_now } }

      record = order.reload
      assert_equal [ "cancelled", "not confirmed in time" ], [ record.state, record.cancel_reason ]
      assert_equal 10, available("MUG")
    end

    test "an order paid in time is left alone" do
      order = place
      perform_due_jobs

      travel(31.minutes) { DeadlineSweepJob.perform_now }

      assert_equal "paid", order.reload.status
    end

    test "a deadline passing while the confirmation is running leaves the order cancelled and gives back what the run took" do
      order = checkout
      # The sweep runs while confirming is between the reservation and the authorization.
      sweep = -> { travel(3.minutes) { DeadlineSweepJob.perform_now; perform_enqueued_jobs(only: CancelJob) } }
      before_calling(Payments::Api, :authorize, sweep) { perform_enqueued_jobs(only: ConfirmJob) }
      perform_due_jobs

      record = order.reload
      assert_equal [ "cancelled", "not confirmed in time" ], [ record.state, record.cancel_reason ]
      assert_equal 10, available("MUG")
      assert_equal :voided, Payments::TestSupport.money_status(order.reference)
    end

    test "a sweep's cancellations share the sweep's run as their flow" do
      2.times { place }
      clear_enqueued_jobs

      published = travel(31.minutes) { record_publications { perform_enqueued_jobs { DeadlineSweepJob.perform_later } } }

      assert_equal 2, published.count { |publication| publication.event_type == "orders.order_cancelled" }
      assert_equal 1, published.map(&:correlation_id).uniq.size
      assert published.first.correlation_id
    end
  end
end
