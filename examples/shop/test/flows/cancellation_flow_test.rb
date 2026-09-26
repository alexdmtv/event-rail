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
      work_off_queue # every job, the carrier's too: nothing may leave
    end

    assert_equal "cancelled", Orders::Api.order(order.id).state
    assert_equal "refunded", Payments::Api.payment(order.reference).state
    shipment = Fulfillment::Api.shipment(order.reference)
    assert_equal "cancelled", shipment.state
    assert_nil shipment.dispatched_at
    assert_equal 10, available("MUG")
    assert_equal 10, on_hand("MUG")
    assert_equal 0, points(order)
    assert_one_flow(order, published)
  end

  test "cancelling an order whose capture landed before the order heard of it refunds it" do
    order = checkout
    Platform::FaultSettings.force_failures("Orders::MarkPaidJob", 1)
    work_off_queue(due_only: true) # captured; recording it on the order failed and waits to retry
    assert_equal [ "placed", "captured" ], [ Orders::Api.order(order.id).state, Payments::Api.payment(order.reference).state ]

    published = record_publications do
      Orders::Api.cancel(order.id)
      work_off_queue
    end

    assert_equal "cancelled", Orders::Api.order(order.id).state
    assert_equal "refunded", Payments::Api.payment(order.reference).state
    assert_nil Fulfillment::Api.shipment(order.reference).dispatched_at
    assert_equal 10, on_hand("MUG")
    assert_equal %w[ cancelled placed ], notified_kinds(order)
    assert_one_flow(order, published)
  end

  test "an abandoned order whose capture had in fact landed is refunded" do
    order = checkout
    Platform::FaultSettings.force_failures("Orders::MarkPaidJob", 1)
    work_off_queue(due_only: true)

    travel(31.minutes) do
      Orders::Api.expire_abandoned_orders
      work_off_queue
    end

    reloaded = Orders::Api.order(order.id)
    assert_equal [ "cancelled", "abandoned" ], [ reloaded.state, reloaded.cancel_reason ]
    assert_equal "refunded", Payments::Api.payment(order.reference).state
  end

  test "an order the carrier has dispatched cannot be cancelled, even before the order has heard" do
    Platform::FaultSettings.current.update!(carrier_delay_seconds: 0)
    order = checkout
    Platform::FaultSettings.force_failures("Orders::MarkShippedJob", 1)
    work_off_queue(due_only: true) # dispatched and delivered; the order still thinks it is paid
    assert_equal "paid", Orders::Api.order(order.id).state

    assert_raises(Orders::Api::NotCancellable) { Orders::Api.cancel(order.id) }

    work_off_queue
    assert_equal "delivered", Orders::Api.order(order.id).state
    assert_equal "captured", Payments::Api.payment(order.reference).state
    assert_equal 8, on_hand("MUG")
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
