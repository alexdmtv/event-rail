require_relative "flow_test_case"

class OrderLifecycleTest < FlowTestCase
  test "an order is placed, paid, shipped and delivered, and every module agrees" do
    order, published = place_and_settle

    assert_equal "delivered", order.status
    assert_equal :captured, Payments::TestSupport.money_status(order.reference)
    assert_equal :delivered, Fulfillment::TestSupport.shipment_status(order.reference)
    assert_equal 8, on_hand("MUG")
    assert_equal %w[ delivered placed shipped ], notified_kinds(order)
    assert_equal 38, points(order)
    assert_empty @job_failures
    assert_one_flow(published)
  end

  test "temporary payment failures are retried without any other module noticing" do
    Payments::TestSupport.provider_times_out(:capture, times: 2)

    order, published = place_and_settle

    assert_equal "delivered", order.status
    assert_equal %w[ delivered placed shipped ], notified_kinds(order)
    assert_one_flow(published)
  end

  test "a refused capture cancels the order and nothing ships" do
    Payments::TestSupport.provider_refuses(:capture)

    order, published = place_and_settle

    assert_equal "cancelled", order.state
    assert_equal :voided, Payments::TestSupport.money_status(order.reference), "the refused capture's hold is voided"
    assert_not Fulfillment::TestSupport.dispatched?(order.reference)
    assert_equal 10, available("MUG")
    assert_equal %w[ cancelled placed ], notified_kinds(order)
    assert_equal 0, points(order)
    assert_one_flow(published)
  end

  test "a capture that never answers leaves the order to its payment deadline, and its payment to the capture's replay" do
    Payments::TestSupport.provider_times_out(:capture, times: 10)

    order, placed = place_and_settle
    capture_failures = @job_failures
    assert_equal 1, capture_failures.size, "the capture ends in the failed jobs"
    swept = travel(31.minutes) { record_publications { enqueue_scheduled(:enforce_order_deadlines); settle } }

    order = Orders::TestSupport.order(order.id)
    assert_equal [ "cancelled", "not paid in time" ], [ order.state, order.cancel_reason ]
    assert_equal :capture, Payments::TestSupport.pending_request(order.reference), "nobody knows whether the capture was taken"
    assert Payments::TestSupport.release_requested?(order.reference), "the release waits for the capture's answer"
    assert_empty @job_failures, "nothing else fails while it waits"

    replayed = travel(32.minutes) { record_publications { replay(capture_failures); settle } } # the provider is back

    assert_equal :refunded, Payments::TestSupport.money_status(order.reference)
    assert_nil Payments::TestSupport.pending_request(order.reference)
    assert_equal %w[ cancelled placed ], notified_kinds(order)
    assert_not_equal assert_one_flow(placed), assert_one_flow(swept), "the sweep's run is a flow of its own"
    assert_equal flow_of(placed), assert_one_flow(replayed), "a replayed job stays in the flow it was started in"
  end

  test "an order whose follow-up the queue could not take at the commit is delivered without the caller retrying" do
    order = nil
    published = record_publications do
      order = refusing_enqueue { checkout }
      relay_staged_jobs
      work_off_queue
    end

    assert_equal "delivered", Orders::TestSupport.order(order.id).status
    assert_equal 1, published.count { |publication| publication.event_type == "orders.order_placed" }
    assert_one_flow(published)
  end

  test "a cart placed twice runs exactly the jobs a cart placed once runs" do
    placed_once = jobs_run { checkout }
    cart_id = Orders::TestSupport.open_cart(customer: Orders::TestSupport::CUSTOMER, items: Orders::TestSupport::ITEMS)
    placed_twice = jobs_run { 2.times { Orders::TestSupport.place_order(cart_id) } }

    assert_equal placed_once, placed_twice
  end

  private
    def jobs_run
      runs = Hash.new(0)
      count = ->(event) { runs[event.payload[:job].class.name] += 1 }
      ActiveSupport::Notifications.subscribed(count, "perform.active_job") do
        yield
        work_off_queue
      end
      runs
    end
end
