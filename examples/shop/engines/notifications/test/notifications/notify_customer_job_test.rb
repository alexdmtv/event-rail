require "test_helper"

module Notifications
  class NotifyCustomerJobTest < ActiveSupport::TestCase
    CUSTOMER = { customer_id: "cus_ada", customer_name: "Ada Lovelace", customer_email: "ada@example.com" }.freeze

    def placed_v2 = Orders::Events::OrderPlaced.new(order_id: "7", **CUSTOMER, total: { amount_cents: 3870, currency: "EUR" }, line_items: [])
    def placed_v1 = Orders::Events::OrderPlacedV1.new(order_id: "7", **CUSTOMER, total_cents: 3870, line_items: [])
    def publish(event) = EventRail.publish(event).event

    test "a placed order is confirmed to its customer" do
      NotifyCustomerJob.perform_now(publish(placed_v2))

      notification = Api.for_order("7").sole
      assert_equal "placed", notification.kind
      assert_equal "ada@example.com", notification.customer_email
      assert_includes notification.body, "€38.70"
    end

    test "a version 1 delivery still queued from before the upgrade is handled" do
      NotifyCustomerJob.perform_now(publish(placed_v1))

      assert_includes Api.for_order("7").sole.body, "€38.70"
    end

    test "a redelivered event records nothing new" do
      event = publish(placed_v2)

      2.times { NotifyCustomerJob.perform_now(event) }

      assert_equal 1, Api.for_order("7").size
    end

    test "every customer-facing order fact is notified" do
      [
        placed_v2,
        Orders::Events::OrderShipped.new(order_id: "7", **CUSTOMER, tracking_code: "TRK-1"),
        Orders::Events::OrderDelivered.new(order_id: "7", **CUSTOMER, total: { amount_cents: 3870, currency: "EUR" }),
        Orders::Events::OrderRefunded.new(order_id: "7", **CUSTOMER, total: { amount_cents: 3870, currency: "EUR" }),
        Orders::Events::OrderCancelled.new(order_id: "7", **CUSTOMER, reason: "customer")
      ].each { |event| NotifyCustomerJob.perform_now(publish(event)) }

      assert_equal %w[ cancelled delivered placed refunded shipped ], Api.for_order("7").map(&:kind).sort
    end

    test "a notification that keeps failing is given up after three attempts" do
      event = publish(placed_v2)
      clear_enqueued_jobs
      Notification.define_singleton_method(:insert) { |*, **| raise "mail relay down" }

      perform_enqueued_jobs { NotifyCustomerJob.perform_later(event) }

      assert_performed_jobs 3
      assert_no_enqueued_jobs
    ensure
      Notification.singleton_class.remove_method(:insert)
    end
  end
end
