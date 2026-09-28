require_relative "flow_test_case"

class OrderLifecycleTest < FlowTestCase
  test "an order is placed, paid, shipped and delivered, and every module agrees" do
    order, published = place_and_settle

    assert_equal "delivered", order.status
    assert_equal "captured", Payments::Api.payment(order.reference).state
    assert_equal "delivered", Fulfillment::Api.shipment(order.reference).state
    assert_equal 8, on_hand("MUG")
    assert_equal %w[ delivered placed shipped ], notified_kinds(order)
    assert_equal 38, points(order)
    assert_empty @job_failures
    assert_one_flow(order, published)
  end

  test "temporary payment failures are retried without any other module noticing" do
    Payments::Gateway.adapter = gateway = ScriptedGateway.new(capture: [ :timeout, :timeout ])

    order, published = place_and_settle

    assert_equal "delivered", order.status
    assert_equal 3, gateway.calls[:capture]
    assert_equal %w[ delivered placed shipped ], notified_kinds(order)
    assert_one_flow(order, published)
  end

  test "a refused capture cancels the order and nothing ships" do
    Payments::Gateway.adapter = ScriptedGateway.new(capture: [ :refuse ])

    order, published = place_and_settle

    assert_equal "cancelled", order.state
    payment = Payments::Api.payment(order.reference)
    assert_equal "capture_failed", payment.state
    assert payment.voided_at, "the refused capture's hold is voided"
    assert_nil Fulfillment::Api.shipment(order.reference)&.dispatched_at
    assert_equal 10, available("MUG")
    assert_equal %w[ cancelled placed ], notified_kinds(order)
    assert_equal 0, points(order)
    assert_one_flow(order, published)
  end

  test "a capture that never succeeds leaves the order to its payment deadline, within the order's flow" do
    Payments::Gateway.adapter = gateway = ScriptedGateway.new(capture: [ :timeout ] * 10)

    order, published = place_and_settle
    assert_equal [ "Payments::CaptureJob" ], @job_failures.map(&:job_class), "the capture ends in the failed jobs"
    published += travel(31.minutes) { record_publications { enqueue_scheduled(:enforce_order_deadlines); settle } }

    assert_equal 10, gateway.calls[:capture]
    order = Orders::Api.order(order.id)
    assert_equal "cancelled", order.state
    assert_equal "not paid in time", order.cancel_reason
    assert Payments::Api.payment(order.reference).voided_at, "the hold is voided"
    assert_equal %w[ cancelled placed ], notified_kinds(order)
    assert_one_flow(order, published)
  end

  test "an order whose follow-up the queue could not take at the commit is delivered without the caller retrying" do
    order = refusing_enqueue { checkout }

    published = record_publications do
      relay_staged_jobs
      work_off_queue
    end

    assert_equal "delivered", Orders::Api.order(order.id).status
    assert_equal 1, published.count { |publication| publication.event_type == "orders.order_placed" }
    assert_one_flow(order, published)
  end

  test "a cart placed twice runs exactly the jobs a cart placed once runs" do
    placed_once = jobs_run { checkout }
    cart = Orders::Api.open_cart(customer: ShopHelpers::CUSTOMER, items: { "MUG" => 2, "TEA" => 1 })
    placed_twice = jobs_run { 2.times { Orders::Api.place_order(cart.id) } }

    assert_equal placed_once, placed_twice
    assert_equal 1, placed_twice["Orders::ConfirmJob"]
  end

  private
    # How often each job class ran while the block's orders were placed and settled.
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
