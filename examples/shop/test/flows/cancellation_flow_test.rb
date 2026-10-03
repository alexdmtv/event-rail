require_relative "flow_test_case"

class CancellationFlowTest < FlowTestCase
  setup { slow_carrier }

  test "cancelling before capture voids the authorization and releases the stock" do
    order = place
    clear_enqueued_jobs # its capture has not run

    published = record_publications do
      Orders::TestSupport.request_cancellation(order.id)
      @job_failures = work_off_queue(due_only: true)
    end

    assert_equal "cancelled", Orders::TestSupport.order(order.id).state
    assert_equal "voided", Payments::TestSupport.payment(order.reference).state
    assert_equal 10, available("MUG")
    assert_includes notified_kinds(order), "cancelled"
    assert_one_flow(published)
  end

  test "cancelling a paid order before dispatch refunds it" do
    order = place
    work_off_queue(due_only: true)
    assert_equal "paid", Orders::TestSupport.order(order.id).status

    published = record_publications do
      Orders::TestSupport.request_cancellation(order.id)
      work_off_queue(due_only: true) # the cancellation, before the carrier comes
      work_off_queue # and then every job, the carrier's too: nothing may leave
    end

    assert_equal "cancelled", Orders::TestSupport.order(order.id).state
    assert_equal "refunded", Payments::TestSupport.payment(order.reference).state
    shipment = Fulfillment::TestSupport.shipment(order.reference)
    assert_equal "cancelled", shipment.state
    assert_nil shipment.dispatched_at
    assert_equal 10, available("MUG")
    assert_equal 10, on_hand("MUG")
    assert_equal 0, points(order)
    assert_one_flow(published)
  end

  test "cancelling an order whose capture landed before the order heard of it refunds it" do
    order = place
    failing_runs("Orders::MarkPaidJob", 1) do
      work_off_queue(due_only: true) # captured; recording it on the order failed and waits to retry
    end
    assert_equal [ "confirmed", "captured" ], [ Orders::TestSupport.order(order.id).state, Payments::TestSupport.payment(order.reference).state ]

    published = record_publications do
      Orders::TestSupport.request_cancellation(order.id)
      work_off_queue
    end

    assert_equal "cancelled", Orders::TestSupport.order(order.id).state
    assert_equal "refunded", Payments::TestSupport.payment(order.reference).state
    assert_nil Fulfillment::TestSupport.shipment(order.reference).dispatched_at
    assert_equal 10, on_hand("MUG")
    assert_equal %w[ cancelled placed ], notified_kinds(order)
    assert_one_flow(published)
  end

  test "an unpaid order whose capture had in fact landed is refunded" do
    order = place
    failures = failing_runs("Orders::MarkPaidJob", 10) do # every attempt
      work_off_queue(due_only: true) + work_off_queue # its retries, until it ends in the failed jobs
    end
    assert_equal [ "Orders::MarkPaidJob" ], failures.map(&:job_class)

    travel(31.minutes) do
      enqueue_scheduled(:enforce_order_deadlines)
      work_off_queue
    end

    reloaded = Orders::TestSupport.order(order.id)
    assert_equal [ "cancelled", "not paid in time" ], [ reloaded.state, reloaded.cancel_reason ]
    assert_equal "refunded", Payments::TestSupport.payment(order.reference).state
  end

  test "a cancellation of an order the carrier has dispatched, before the order has heard, is refused and the order carries on" do
    instant_carrier
    order = place
    failing_runs("Orders::MarkShippedJob", 1) do
      work_off_queue(due_only: true) # dispatched and delivered; the order still thinks it is paid
    end
    assert_equal "paid", Orders::TestSupport.order(order.id).status

    Orders::TestSupport.request_cancellation(order.id)
    work_off_queue

    reloaded = Orders::TestSupport.order(order.id)
    assert reloaded.cancellation_refused_at, "Fulfillment refused it: the parcel had left"
    assert_equal "delivered", reloaded.status
    assert_equal "captured", Payments::TestSupport.payment(order.reference).state
    assert_equal 8, on_hand("MUG")
  end

  test "a dispatched order cannot be cancelled and carries on" do
    instant_carrier
    order, = place_and_settle

    assert_raises(Orders::NotCancellable) { Orders::TestSupport.request_cancellation(order.id) }
    assert_equal "delivered", Orders::TestSupport.order(order.id).status
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

    reloaded = Orders::TestSupport.order(order.id)
    assert_equal "cancelled", reloaded.state
    assert_equal "not paid in time", reloaded.cancel_reason
    assert_equal "voided", Payments::TestSupport.payment(order.reference).state
    assert_equal 10, available("MUG")
    assert_equal %w[ cancelled ], notified_kinds(order)
    assert_one_flow(published)
  end
end
