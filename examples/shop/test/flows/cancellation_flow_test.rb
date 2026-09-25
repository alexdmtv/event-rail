require_relative "flow_test_case"

class CancellationFlowTest < FlowTestCase
  setup { slow_carrier }

  test "cancelling before capture voids the authorization and releases the stock" do
    order = checkout

    published = record_publications do
      Orders::Api.cancel(order.id)
      @job_failures = work_off_queue(due_only: true)
    end

    assert_equal "cancelled", Orders::Api.order(order.id).state
    assert_equal "voided", Payments::Api.payment(order.reference).state
    assert_equal 10, available("MUG")
    assert_includes notified_kinds(order), "cancelled"
    assert_one_flow(order, published)
  end

  test "cancelling a paid order before dispatch refunds it" do
    order = checkout
    published = record_publications { work_off_queue(due_only: true) }
    assert_equal "paid", Orders::Api.order(order.id).state

    published += record_publications do
      Orders::Api.cancel(order.id)
      work_off_queue(due_only: true)
    end

    assert_equal "cancelled", Orders::Api.order(order.id).state
    assert_equal "refunded", Payments::Api.payment(order.reference).state
    assert_equal 10, available("MUG")
    assert_equal 0, points(order)
    assert_one_flow(order, published)
  end

  test "a dispatched order cannot be cancelled and carries on" do
    Platform::FaultSettings.current.update!(carrier_delay_seconds: 0)
    order, = place_and_settle

    assert_raises(Orders::Api::NotCancellable) { Orders::Api.cancel(order.id) }
    assert_equal "delivered", Orders::Api.order(order.id).state
  end

  test "an abandoned checkout is cancelled after 30 minutes and gives everything back" do
    order = checkout
    clear_enqueued_jobs # its follow-up never ran

    published = travel(31.minutes) do
      record_publications do
        Orders::Api.expire_abandoned_orders
        work_off_queue
      end
    end

    reloaded = Orders::Api.order(order.id)
    assert_equal "cancelled", reloaded.state
    assert_equal "abandoned", reloaded.cancel_reason
    assert_equal "voided", Payments::Api.payment(order.reference).state
    assert_equal 10, available("MUG")
    assert_equal %w[ cancelled ], notified_kinds(order)
    assert_one_flow(order, published)
  end
end
