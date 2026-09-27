require "test_helper"
require_relative "../support/order_records"

module Orders
  class ExpiryTest < ActiveSupport::TestCase
    include ShopHelpers
    include OrderRecords

    setup do
      stock_shelves
      slow_carrier
    end

    test "an order still unpaid after 30 minutes is cancelled as abandoned" do
      order = place
      clear_enqueued_jobs # its capture never ran

      travel 31.minutes do
        perform_enqueued_jobs { ExpireAbandonedOrdersJob.perform_now }
      end

      record = order_record(order)
      assert_equal "cancelled", record.state
      assert_equal "abandoned", record.cancel_reason
      assert_equal 10, available("MUG")
      assert_equal "voided", Payments::Api.payment(order.reference).state
    end

    test "an order still pending after 30 minutes is rejected, and what its placement took is given back" do
      order = checkout
      failing(Payments::Api, :authorize) { perform_enqueued_jobs(only: PlaceOrderJob) } # reserved, then failed
      clear_enqueued_jobs # as if its placement had failed for good
      assert_equal 8, available("MUG")

      travel 31.minutes do
        perform_enqueued_jobs { ExpireAbandonedOrdersJob.perform_now }
      end

      record = order_record(order)
      assert_equal "rejected", record.state
      assert_equal "not placed in time", record.rejection_reason
      assert_equal 10, available("MUG")
    end

    test "an expiry overtaking a placement in flight leaves the order rejected and gives back what the placement took" do
      order = checkout
      test = self
      # The expiry runs while the placement is between its reservation and its authorization.
      Payments::Api.singleton_class.alias_method :__authorize_before_expiry, :authorize
      Payments::Api.define_singleton_method(:authorize) do |**options|
        test.travel(31.minutes) { Orders::Api.expire_abandoned_orders }
        __authorize_before_expiry(**options)
      end

      perform_enqueued_jobs(only: PlaceOrderJob)
      Payments::Api.singleton_class.alias_method :authorize, :__authorize_before_expiry
      perform_due_jobs

      record = order_record(order)
      assert_equal "rejected", record.state
      assert_equal "not placed in time", record.rejection_reason
      assert_equal 10, available("MUG")
      assert_equal "voided", Payments::Api.payment(order.reference).state
    ensure
      if Payments::Api.singleton_class.method_defined?(:__authorize_before_expiry)
        Payments::Api.singleton_class.alias_method :authorize, :__authorize_before_expiry
        Payments::Api.singleton_class.remove_method :__authorize_before_expiry
      end
    end

    test "an order paid within 30 minutes is left alone" do
      order = checkout
      perform_due_jobs

      travel 31.minutes do
        ExpireAbandonedOrdersJob.perform_now
      end

      assert_equal "paid", order_record(order).state
    end

    test "an abandoned order's cancellation joins its own flow" do
      order = place
      clear_enqueued_jobs

      published = travel(31.minutes) { record_publications { perform_enqueued_jobs { ExpireAbandonedOrdersJob.perform_now } } }

      assert_equal [ order.correlation_id ], published.map(&:correlation_id).uniq
    end
  end
end
