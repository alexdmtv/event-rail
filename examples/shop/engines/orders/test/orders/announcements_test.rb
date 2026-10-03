require "test_helper"

module Orders
  class AnnouncementsTest < ActiveSupport::TestCase
    include ShopHelpers

    setup { stock_shelves }

    test "every event carries the order's customer, and the ones about money its total" do
      announcements = Order.find(checkout.id).announcements
      events = %i[ placed cancelled shipped delivered refunded ].map { |name| announcements.public_send(name) }

      events.each do |event|
        assert event.valid?, "#{event.class.name}: #{event.errors.full_messages.to_sentence}"
        assert_equal [ "cus_ada", "ada@example.com" ], [ event.customer_id, event.customer_email ]
      end
      assert_equal [ 2 * 1490 + 890 ] * 3, [ announcements.placed, announcements.delivered, announcements.refunded ].map { |event| event.total.amount_cents }
      assert_equal [ [ "MUG", 2 ], [ "TEA", 1 ] ], announcements.placed.line_items.map { |line| [ line.sku, line.quantity ] }.sort
    end
  end
end
