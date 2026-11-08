require_relative "flow_test_case"

class OrderLifecycleTest < FlowTestCase
  test "an order is placed, paid, shipped and delivered, and every module agrees" do
    order, published = place_and_settle

    assert_equal :delivered, order.status
    assert_equal :captured, Payments::TestSupport.money_status(order.reference)
    assert_equal :delivered, Fulfillment::TestSupport.shipment_status(order.reference)
    assert_equal 2, shipped("MUG")
    assert_equal %i[ delivered placed shipped ], notified_kinds(order)
    assert_operator points(order), :>, 0
    assert_empty @job_failures
    assert_one_flow(published)
  end

  test "temporary payment failures are retried without any other module noticing" do
    Payments::TestSupport.provider_times_out(:capture, times: 2)

    order, published = place_and_settle

    assert_equal :delivered, order.status
    assert_equal %i[ delivered placed shipped ], notified_kinds(order)
    assert_one_flow(published)
  end

  test "a refused capture cancels the order and nothing ships" do
    Payments::TestSupport.provider_refuses(:capture)

    order, published = place_and_settle

    assert_equal :cancelled, order.state
    assert_equal :payment_refused, order.cancel_cause
    assert_equal :voided, Payments::TestSupport.money_status(order.reference), "the refused capture's hold is voided"
    assert_equal :cancelled, Fulfillment::TestSupport.shipment_status(order.reference), "nothing was asked of the carrier, and nothing can be now"
    assert_equal 0, held("MUG")
    assert_equal %i[ cancelled placed ], notified_kinds(order)
    assert_equal 0, points(order)
    assert_one_flow(published)
  end

  test "a capture that never answers leaves the order to its payment deadline, and its payment to the capture's replay" do
    Payments::TestSupport.provider_stops_answering(:capture)

    order, placed = place_and_settle
    capture_failures = @job_failures
    assert_equal 1, capture_failures.size, "the capture ends in the failed jobs"
    swept = travel(31.minutes) { record_publications { enqueue_scheduled(:enforce_order_deadlines); settle } }

    order = Orders::TestSupport.order(order.id)
    assert_equal [ :cancelled, :not_paid_in_time ], [ order.state, order.cancel_cause ]
    assert_equal :capture, Payments::TestSupport.pending_request(order.reference), "nobody knows whether the capture was taken"
    assert Payments::TestSupport.release_requested?(order.reference), "the release waits for the capture's answer"
    assert_empty @job_failures, "nothing else fails while it waits"

    Payments::TestSupport.provider_answers_again(:capture)
    replayed = travel(32.minutes) { record_publications { replay(capture_failures); settle } }

    assert_equal :refunded, Payments::TestSupport.money_status(order.reference)
    assert_nil Payments::TestSupport.pending_request(order.reference)
    assert_equal %i[ cancelled placed ], notified_kinds(order)
    assert_not_equal assert_one_flow(placed), assert_one_flow(swept), "the sweep's run is a flow of its own"
    assert_equal flow_of(placed), assert_one_flow(replayed), "a replayed job stays in the flow it was started in"
  end

  test "an order whose follow-up the queue could not take at the commit is delivered without the caller retrying" do
    order = nil
    published = record_publications do
      order = refusing_enqueue { Orders::TestSupport.checkout }
      relay_staged_jobs
      work_off_queue
    end

    assert_equal :delivered, Orders::TestSupport.order(order.id).status
    assert_equal 1, published.count { |publication| publication.event_type == "orders.order_placed" }
    assert_one_flow(published)
  end

  test "a cart placed twice causes exactly what a cart placed once causes" do
    placed_once = facts_announced { Orders::TestSupport.checkout }
    cart_id = Orders::TestSupport.open_cart(customer: Orders::TestSupport::CUSTOMER, items: Orders::TestSupport::ITEMS)
    placed_twice = facts_announced { 2.times { Orders::TestSupport.place_order(cart_id) } }

    assert_equal placed_once, placed_twice
    assert_equal 1, placed_twice["orders.order_placed"]
  end

  private
    # How many times each fact was announced, by event type, once everything it caused has run.
    def facts_announced(&block) = record_publications { block.call; work_off_queue }.map(&:event_type).tally
end
