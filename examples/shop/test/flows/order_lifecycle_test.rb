require_relative "flow_test_case"

class OrderLifecycleTest < FlowTestCase
  test "an order is placed, paid, shipped and delivered, and every module agrees" do
    order, published = place_and_settle

    assert_equal "delivered", order.state
    assert_equal "captured", Payments::Api.payment(order.reference).state
    assert_equal "delivered", Fulfillment::Api.shipment(order.reference).state
    assert_equal 8, on_hand("MUG")
    assert_equal %w[ delivered placed shipped ], notified_kinds(order)
    assert_equal 38, points(order)
    assert_empty @job_failures
    assert_one_flow(order, published)
  end

  test "temporary payment failures are retried without any other module noticing" do
    Payments::Gateway.adapter = gateway = ScriptedGateway.new(capture: [ :timeout, :timeout ])

    order, published = place_and_settle

    assert_equal "delivered", order.state
    assert_equal 3, gateway.calls[:capture]
    assert_equal %w[ delivered placed shipped ], notified_kinds(order)
    assert_one_flow(order, published)
  end

  test "a refused capture cancels the order and nothing ships" do
    Payments::Gateway.adapter = ScriptedGateway.new(capture: [ :refuse ])

    order, published = place_and_settle

    assert_equal "cancelled", order.state
    assert_equal "capture_failed", Payments::Api.payment(order.reference).state
    assert_nil Fulfillment::Api.shipment(order.reference)
    assert_equal 10, available("MUG")
    assert_equal %w[ cancelled placed ], notified_kinds(order)
    assert_equal 0, points(order)
    assert_one_flow(order, published)
  end

  test "a checkout whose follow-up was never scheduled is resumed by the customer's retry" do
    Orders::FollowUpJob.define_singleton_method(:perform_later_as) { |*| raise "queue unavailable" }
    assert_raises(RuntimeError) { checkout }
    Orders::FollowUpJob.singleton_class.remove_method(:perform_later_as)

    order, published = place_and_settle

    assert_equal "delivered", order.state
    assert_equal 1, Orders::Api.recent.size
    assert_equal 1, published.count { |publication| publication.event_type == "orders.order_placed" }
    assert_one_flow(order, published)
  end
end
