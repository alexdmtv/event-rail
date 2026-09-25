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
      order = checkout

      travel 31.minutes do
        ExpireAbandonedOrdersJob.perform_now
        perform_enqueued_jobs(except: FollowUpJob) # the void, not the never-run follow-up
      end

      record = order_record(order)
      assert_equal "cancelled", record.state
      assert_equal "abandoned", record.cancel_reason
      assert_equal 10, available("MUG")
      assert_equal "voided", Payments::Api.payment(order.reference).state
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
      order = checkout

      published = travel(31.minutes) { record_publications { ExpireAbandonedOrdersJob.perform_now } }

      assert_equal [ order.correlation_id ], published.map(&:correlation_id)
    end
  end
end
