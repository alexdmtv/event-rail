require_relative "flow_test_case"

# How the domain events a request causes appear in the structured event log as they are handled.
class ObservabilityFlowTest < FlowTestCase
  test "a subscriber handling a domain event appears with its job" do
    Orders::TestSupport.checkout
    event = assert_event_reported("event_rail.subscriber_performed", payload: { event_type: "orders.order_placed" }) { work_off_queue }

    assert_match(/\A\w+::\w+Job\z/, event[:payload][:job_class])
  end

  test "a subscriber's context names the domain event it handles, which anything it stages names as its cause" do
    shipped = assert_event_reported("event_rail.staged", payload: { event_type: "orders.order_shipped" }) { place_and_settle }

    assert_equal shipped[:context][:message_id], shipped[:payload][:causation_id]
    assert_not_equal shipped[:context][:job_id], shipped[:context][:message_id], "a subscriber's message is the event it handles, not its job"
  end
end
