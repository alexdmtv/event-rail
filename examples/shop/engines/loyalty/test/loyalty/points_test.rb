require "test_helper"

module Loyalty
  class PointsTest < ActiveSupport::TestCase
    CUSTOMER = { customer_id: "cus_ada", customer_name: "Ada Lovelace", customer_email: "ada@example.com" }.freeze
    TOTAL = { amount_cents: 4990, currency: "EUR" }.freeze

    def delivered = EventRail.publish(Orders::Events::OrderDelivered.new(order_id: "7", **CUSTOMER, total: TOTAL)).event
    def refunded = EventRail.publish(Orders::Events::OrderRefunded.new(order_id: "7", **CUSTOMER, total: TOTAL)).event

    test "a delivered order earns one point per whole euro" do
      AwardPointsJob.perform_now(delivered)

      assert_equal 49, Api.balance("cus_ada")
    end

    test "a refunded order gives its points back" do
      AwardPointsJob.perform_now(delivered)
      RevokePointsJob.perform_now(refunded)

      assert_equal 0, Api.balance("cus_ada")
      assert_equal({ "7" => 0 }, Api.points_for_orders([ 7 ]))
    end

    test "a redelivered event changes no balance" do
      event = delivered

      2.times { AwardPointsJob.perform_now(event) }

      assert_equal 49, Api.balance("cus_ada")
    end

    test "the same fact republished under a new identity changes no balance" do
      AwardPointsJob.perform_now(delivered)
      AwardPointsJob.perform_now(delivered)

      assert_equal 49, Api.balance("cus_ada")
    end
  end
end
