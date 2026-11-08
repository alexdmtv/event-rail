require "test_helper"

module Loyalty
  class PointsTest < ActiveSupport::TestCase
    CUSTOMER = { customer_id: "cus_ada", customer_name: "Ada Lovelace", customer_email: "ada@example.com" }.freeze
    TOTAL = { amount_cents: 4990, currency: "EUR" }.freeze

    def delivered = EventRail.publish(Orders::Events::OrderDelivered.new(order_id: "7", **CUSTOMER, total: TOTAL)).event
    def refunded = EventRail.publish(Orders::Events::OrderRefunded.new(order_id: "7", **CUSTOMER, total: TOTAL)).event
    def balance = Entry.where(customer_id: "cus_ada").sum(:points)

    test "a delivered order earns one point per whole euro" do
      perform_once(AwardPointsJob, delivered)

      assert_equal 49, balance
    end

    test "a refunded order gives its points back" do
      perform_once(AwardPointsJob, delivered)
      perform_once(RevokePointsJob, refunded)

      assert_equal 0, balance
      assert_equal 0, Entry.where(order_id: "7").sum(:points)
    end

    test "a redelivered event changes no balance" do
      event = delivered

      2.times { perform_once(AwardPointsJob, event) }

      assert_equal 49, balance
    end

    test "the same fact republished under a new identity changes no balance" do
      perform_once(AwardPointsJob, delivered)
      perform_once(AwardPointsJob, delivered)

      assert_equal 49, balance
    end
  end
end
