require_relative "flow_test_case"

class OrderLifecycleTest < FlowTestCase
  test "an order is placed, paid, shipped and delivered, and every module agrees" do
    order, published = place_and_settle

    assert_equal "delivered", order.state
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

    assert_equal "delivered", order.state
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

  test "a capture that keeps timing out cancels the order, within the order's flow" do
    Payments::Gateway.adapter = gateway = ScriptedGateway.new(capture: [ :timeout ] * 5)

    order, published = place_and_settle

    assert_equal 5, gateway.calls[:capture]
    assert_equal "cancelled", order.state
    payment = Payments::Api.payment(order.reference)
    assert_equal "capture_failed", payment.state
    assert payment.voided_at, "the hold is voided"
    assert_includes published.map(&:event_type), "payments.capture_failed"
    assert_equal %w[ cancelled placed ], notified_kinds(order)
    assert_one_flow(order, published)
  end

  test "an order whose follow-up the queue could not take at the commit is delivered without the caller retrying" do
    queue_adapter.define_singleton_method(:enqueue) { |*| raise "queue unavailable" }
    order = checkout
    queue_adapter.singleton_class.remove_method(:enqueue)

    published = record_publications do
      travel(Platform::StagedJob::GRACE + 1.second) { Platform::StagedJobRelayJob.perform_now }
      work_off_queue
    end

    assert_equal "delivered", Orders::Api.order(order.id).state
    assert_equal 1, published.count { |publication| publication.event_type == "orders.order_placed" }
    assert_one_flow(order, published)
  ensure
    queue_adapter.singleton_class.remove_method(:enqueue) if queue_adapter.singleton_class.method_defined?(:enqueue, false)
  end

  test "a double submission runs exactly the jobs a single submission runs" do
    submitted_once = jobs_run { checkout(key: "once") }
    submitted_twice = jobs_run { 2.times { checkout(key: "twice") } }

    assert_equal submitted_once, submitted_twice
    assert_equal 1, submitted_twice["Orders::FollowUpJob"]
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
