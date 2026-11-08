require "test_helper"

module Orders
  class AnnouncementsTest < ActiveSupport::TestCase
    include Steps

    test "every event carries the order's customer, and the ones about money its total" do
      order = checkout_order
      announcements = order.announcements
      events = %i[ placed cancelled shipped delivered refunded ].map { |name| announcements.public_send(name) }

      events.each do |event|
        assert event.valid?, "#{event.class.name}: #{event.errors.full_messages.to_sentence}"
        assert_equal [ "cus_ada", "ada@example.com" ], [ event.customer_id, event.customer_email ]
      end
      assert_equal [ order.total_cents ] * 3, [ announcements.placed, announcements.delivered, announcements.refunded ].map { |event| event.total.amount_cents }
      assert_equal order.line_items.map { |line| [ line.sku, line.quantity, line.unit_price_cents ] }.sort,
        announcements.placed.line_items.map { |line| [ line.sku, line.quantity, line.unit_price_cents ] }.sort
      assert_equal CUSTOMER.name, announcements.placed.customer_name
    end

    test "a cancellation announces its reason" do
      order = checkout_order
      TestSupport.request_cancellation(order.id, reason: "changed my mind")

      assert_equal "changed my mind", order.reload.announcements.cancelled.reason
    end
  end
end
