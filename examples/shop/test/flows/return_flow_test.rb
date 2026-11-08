require_relative "flow_test_case"

class ReturnFlowTest < FlowTestCase
  test "a returned order is restocked and refunded, and its points are taken back" do
    order, placed = place_and_settle
    assert_equal 38, points(order)

    published = record_publications do
      Orders::TestSupport.request_return(order.id)
      work_off_queue
    end

    assert_equal :refunded, Orders::TestSupport.order(order.id).status
    assert_equal :refunded, Payments::TestSupport.money_status(order.reference)
    assert_equal :received, Fulfillment::TestSupport.parcel_return_status(order.reference)
    assert_equal 10, on_hand("MUG")
    assert_equal 0, points(order)
    assert_includes notified_kinds(order), :refunded
    assert_not_equal flow_of(placed), assert_one_flow(published), "the return is a request of its own"
  end

  test "a refused refund sets the order aside and keeps its points" do
    order, = place_and_settle
    Payments::TestSupport.provider_refuses(:refund)

    Orders::TestSupport.request_return(order.id)
    work_off_queue

    reloaded = Orders::TestSupport.order(order.id)
    assert_equal [ :needs_attention, :refund_failed ], [ reloaded.status, reloaded.return_status ]
    assert_equal 38, points(order)
  end
end
