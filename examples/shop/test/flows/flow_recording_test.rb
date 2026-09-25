require_relative "flow_test_case"

class FlowRecordingTest < FlowTestCase
  test "an order's flow is recorded as a tree of causes, with every attempt" do
    Payments::Gateway.adapter = ScriptedGateway.new(capture: [ :timeout, :timeout ])

    order, = place_and_settle
    roots = Observability::Api.flow(order.correlation_id)

    follow_up = roots.sole
    assert_equal "Orders::FollowUpJob", follow_up.name

    placed = follow_up.children.find { |step| step.name == "orders.order_placed" }
    assert_equal 2, placed.version
    assert_includes placed.children.map(&:name), "Notifications::NotifyCustomerJob"

    capture = follow_up.children.find { |step| step.name == "Payments::CaptureJob" }
    assert_equal %w[ failed failed succeeded ], capture.attempts.map(&:outcome)
    assert_equal "Payments::Gateway::TemporaryFailure", capture.attempts.first.error_class

    captured = capture.children.sole
    assert_equal "payments.payment_captured", captured.name
    mark_paid = captured.children.find { |step| step.name == "Orders::MarkPaidJob" }
    assert_includes mark_paid.children.map(&:name), "Fulfillment::DispatchJob"

    names = flatten(roots).map(&:name)
    %w[ orders.order_shipped orders.order_delivered Loyalty::AwardPointsJob ].each { |name| assert_includes names, name }
  end

  test "the observed wiring shows who publishes each event and who reacts to it" do
    place_and_settle

    delivered = Observability::Api.wiring.find { |wiring| wiring.event_type == "orders.order_delivered" }
    assert_equal [ "shop.orders" ], delivered.publishers
    assert_equal %w[ Loyalty::AwardPointsJob Notifications::NotifyCustomerJob ], delivered.subscribers
  end

  private
    def flatten(steps) = steps.flat_map { |step| [ step, *flatten(step.children) ] }
end
