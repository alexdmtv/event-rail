require_relative "flow_test_case"

class ReturnFlowTest < FlowTestCase
  test "a returned order is restocked and refunded, and its points are taken back" do
    order, published = place_and_settle
    assert_equal 38, points(order)

    published += record_publications do
      Orders::Api.request_return(order.id)
      work_off_queue
    end

    assert_equal "refunded", Orders::Api.order(order.id).state
    assert_equal "refunded", Payments::Api.payment(order.reference).state
    assert_equal "received", Fulfillment::Api.parcel_return(order.reference).state
    assert_equal 10, on_hand("MUG")
    assert_equal 0, points(order)
    assert_includes notified_kinds(order), "refunded"
    assert_one_flow(order, published)
  end

  test "a refused refund sets the order aside and keeps its points" do
    order, = place_and_settle
    Payments::Gateway.adapter = ScriptedGateway.new(refund: [ :refuse ])

    Orders::Api.request_return(order.id)
    work_off_queue

    reloaded = Orders::Api.order(order.id)
    assert_equal "needs_attention", reloaded.state
    assert_match(/refund refused/, reloaded.attention_reason)
    assert_equal 38, points(order)
  end
end
