require "test_helper"
require_relative "../support/order_records"

module Orders
  class DeadlinesTest < ActiveSupport::TestCase
    include ShopHelpers
    include OrderRecords

    setup do
      stock_shelves
      slow_carrier
    end

    test "an order not confirmed within two minutes is cancelled, and what confirming took is given back" do
      order = checkout
      failing(Payments::Api, :authorize) { perform_enqueued_jobs(only: ConfirmJob) } # reserved, then failed
      clear_enqueued_jobs # as if the confirmation were stuck
      assert_equal 8, available("MUG")

      travel(3.minutes) { perform_enqueued_jobs { DeadlineSweepJob.perform_now } }

      record = order_record(order)
      assert_equal [ "cancelled", "not confirmed in time" ], [ record.state, record.cancel_reason ]
      assert_equal 10, available("MUG")
    end

    test "a confirmed order not paid within thirty minutes is cancelled, and its hold voided" do
      order = place
      clear_enqueued_jobs # its capture never ran

      travel(31.minutes) { perform_enqueued_jobs { DeadlineSweepJob.perform_now } }

      record = order_record(order)
      assert_equal [ "cancelled", "not paid in time" ], [ record.state, record.cancel_reason ]
      assert_equal "voided", Payments::Api.payment(order.reference).state
    end

    test "an order paid in time is left alone" do
      order = place
      perform_due_jobs

      travel(31.minutes) { DeadlineSweepJob.perform_now }

      assert_equal "paid", order_record(order).status
    end

    test "a deadline passing while the confirmation is running leaves the order cancelled and gives back what the run took" do
      order = checkout
      test = self
      # The sweep runs while confirming is between the reservation and the authorization.
      Payments::Api.singleton_class.alias_method :__authorize_before_deadline, :authorize
      Payments::Api.define_singleton_method(:authorize) do |**options|
        test.travel(3.minutes) { Orders::Api.enforce_deadlines; test.perform_enqueued_jobs(only: CancelJob) }
        __authorize_before_deadline(**options)
      end

      perform_enqueued_jobs(only: ConfirmJob)
      Payments::Api.singleton_class.alias_method :authorize, :__authorize_before_deadline
      perform_due_jobs

      record = order_record(order)
      assert_equal [ "cancelled", "not confirmed in time" ], [ record.state, record.cancel_reason ]
      assert_equal 10, available("MUG")
      assert_equal "voided", Payments::Api.payment(order.reference).state
    ensure
      if Payments::Api.singleton_class.method_defined?(:__authorize_before_deadline)
        Payments::Api.singleton_class.alias_method :authorize, :__authorize_before_deadline
        Payments::Api.singleton_class.remove_method :__authorize_before_deadline
      end
    end

    test "a deadline's cancellation joins the order's flow" do
      order = place
      clear_enqueued_jobs

      published = travel(31.minutes) { record_publications { perform_enqueued_jobs { DeadlineSweepJob.perform_now } } }

      assert_equal [ order.correlation_id ], published.map(&:correlation_id).uniq
    end
  end
end
