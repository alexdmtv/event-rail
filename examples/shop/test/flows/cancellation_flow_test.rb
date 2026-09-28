require_relative "flow_test_case"

class CancellationFlowTest < FlowTestCase
  setup { slow_carrier }

  test "cancelling before capture voids the authorization and releases the stock" do
    order = place
    clear_enqueued_jobs # its capture has not run

    published = record_publications do
      Orders::Api.request_cancellation(order.id)
      @job_failures = work_off_queue(due_only: true)
    end

    assert_equal "cancelled", Orders::Api.order(order.id).state
    assert_equal "voided", Payments::Api.payment(order.reference).state
    assert_equal 10, available("MUG")
    assert_includes notified_kinds(order), "cancelled"
    assert_one_flow(order, published)
  end

  test "cancelling a paid order before dispatch refunds it" do
    order = place
    published = record_publications { work_off_queue(due_only: true) }
    assert_equal "paid", Orders::Api.order(order.id).status

    published += record_publications do
      Orders::Api.request_cancellation(order.id)
      work_off_queue(due_only: true) # the cancellation, before the carrier comes
      work_off_queue # and then every job, the carrier's too: nothing may leave
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
    order = place
    Platform::FaultSettings.force_failures("Orders::MarkPaidJob", 1)
    work_off_queue(due_only: true) # captured; recording it on the order failed and waits to retry
    assert_equal [ "confirmed", "captured" ], [ Orders::Api.order(order.id).state, Payments::Api.payment(order.reference).state ]

    published = record_publications do
      Orders::Api.request_cancellation(order.id)
      work_off_queue
    end

    assert_equal "cancelled", Orders::Api.order(order.id).state
    assert_equal "refunded", Payments::Api.payment(order.reference).state
    assert_nil Fulfillment::Api.shipment(order.reference).dispatched_at
    assert_equal 10, on_hand("MUG")
    assert_equal %w[ cancelled placed ], notified_kinds(order)
    assert_one_flow(order, published)
  end

  test "an unpaid order whose capture had in fact landed is refunded" do
    order = place
    Platform::FaultSettings.force_failures("Orders::MarkPaidJob", 10) # every attempt
    failures = work_off_queue(due_only: true)
    failures += work_off_queue # its retries, until it ends in the failed jobs
    assert_equal [ "Orders::MarkPaidJob" ], failures.map(&:job_class)

    travel(31.minutes) do
      enqueue_scheduled(:enforce_order_deadlines)
      work_off_queue
    end

    reloaded = Orders::Api.order(order.id)
    assert_equal [ "cancelled", "not paid in time" ], [ reloaded.state, reloaded.cancel_reason ]
    assert_equal "refunded", Payments::Api.payment(order.reference).state
  end

  test "a cancellation of an order the carrier has dispatched, before the order has heard, is refused and the order carries on" do
    Platform::FaultSettings.current.update!(carrier_delay_seconds: 0)
    order = place
    Platform::FaultSettings.force_failures("Orders::MarkShippedJob", 1)
    work_off_queue(due_only: true) # dispatched and delivered; the order still thinks it is paid
    assert_equal "paid", Orders::Api.order(order.id).status

    Orders::Api.request_cancellation(order.id)
    work_off_queue

    reloaded = Orders::Api.order(order.id)
    assert reloaded.cancellation_refused_at, "Fulfillment refused it: the parcel had left"
    assert_equal "delivered", reloaded.status
    assert_equal "captured", Payments::Api.payment(order.reference).state
    assert_equal 8, on_hand("MUG")
  end

  test "a dispatched order cannot be cancelled and carries on" do
    Platform::FaultSettings.current.update!(carrier_delay_seconds: 0)
    order, = place_and_settle

    assert_raises(Orders::NotCancellable) { Orders::Api.request_cancellation(order.id) }
    assert_equal "delivered", Orders::Api.order(order.id).status
  end

  test "a confirmed order not paid within 30 minutes is cancelled and gives everything back" do
    order = place
    clear_enqueued_jobs # its capture never ran

    published = travel(31.minutes) do
      record_publications do
        enqueue_scheduled(:enforce_order_deadlines)
        work_off_queue
      end
    end

    reloaded = Orders::Api.order(order.id)
    assert_equal "cancelled", reloaded.state
    assert_equal "not paid in time", reloaded.cancel_reason
    assert_equal "voided", Payments::Api.payment(order.reference).state
    assert_equal 10, available("MUG")
    assert_equal %w[ cancelled ], notified_kinds(order)
    assert_one_flow(order, published)
  end
end
