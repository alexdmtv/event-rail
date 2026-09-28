require "test_helper"

module Notifications
  class NotifyCustomerJobTest < ActiveSupport::TestCase
    CUSTOMER = { customer_id: "cus_ada", customer_name: "Ada Lovelace", customer_email: "ada@example.com" }.freeze

    # A delivery of version 1 of OrderPlaced exactly as the release before version 2 left it in
    # the queue: the subscriber job's serialized argument. Performing it deserializes it, which
    # only works while version 1 is still registered.
    QUEUED_V1_DELIVERY = {
      "_aj_serialized" => "EventRail::Internal::EventSerializer", "format" => 1,
      "event_type" => "orders.order_placed", "event_version" => 1,
      "metadata" => {
        "id" => "d2f4d713-c769-4b2a-b6c5-85c2100a952e", "source" => "shop.orders", "occurred_at" => "2026-09-20T10:00:00.000000Z",
        "correlation_id" => "checkout-before-the-upgrade", "causation_id" => "orders-follow-up-7", "extensions" => {}
      },
      "data" => { "order_id" => "7", **CUSTOMER.transform_keys(&:to_s), "total_cents" => 3870, "line_items" => [] }
    }.freeze

    def placed_v2 = Orders::Events::OrderPlaced.new(order_id: "7", **CUSTOMER, total: { amount_cents: 3870, currency: "EUR" }, line_items: [])
    def placed_v1 = Orders::Events::OrderPlacedV1.new(order_id: "7", **CUSTOMER, total_cents: 3870, line_items: [])
    def publish(event) = EventRail.publish(event).event

    test "a placed order is confirmed to its customer" do
      NotifyCustomerJob.perform_now(publish(placed_v2))

      notification = Api.for_order("7").sole
      assert_equal "placed", notification.kind
      assert_equal "ada@example.com", notification.customer_email
      assert_includes notification.body, "€38.70"
    end

    test "a version 1 delivery still queued from before the upgrade is handled" do
      # Performed soon after it was published, as a delivery left in the queue by the release
      # before is.
      travel_to(Time.utc(2026, 9, 20, 10, 5)) do
        ActiveJob::Base.execute(NotifyCustomerJob.new.serialize.merge("arguments" => [ QUEUED_V1_DELIVERY ]))

        assert_includes Api.for_order("7").sole.body, "€38.70"
      end
    end

    test "a version 1 event is still handled when published" do
      NotifyCustomerJob.perform_now(publish(placed_v1))

      assert_includes Api.for_order("7").sole.body, "€38.70"
    end

    test "the same fact under two identities notifies once" do
      current = publish(Orders::Events::OrderCancelled.new(order_id: "7", **CUSTOMER, reason: "customer"))
      # The same cancellation as a release before the identity change stamped it, under an ID
      # derived the old way: a copy a subscriber can still receive across an upgrade.
      earlier = EventRail::Envelope.new(
        contract: EventRail::Contract.of(Orders::Events::OrderCancelled),
        metadata: EventRail::Metadata.complete(id: "cancelled-before-the-upgrade", source: current.source,
          occurred_at: current.occurred_at, correlation_id: current.correlation_id),
        data: current.data
      ).to_event(Orders::Events::OrderCancelled)
      assert_not_equal current.id, earlier.id

      [ current, earlier ].each { |event| NotifyCustomerJob.perform_now(event) }

      assert_equal [ "cancelled" ], Api.for_order("7").map(&:kind)
    end

    test "a redelivered event records nothing new" do
      event = publish(placed_v2)

      2.times { NotifyCustomerJob.perform_now(event) }

      assert_equal 1, Api.for_order("7").size
    end

    test "every customer-facing order fact is notified" do
      [
        placed_v2,
        Orders::Events::OrderShipped.new(order_id: "7", **CUSTOMER, tracking_code: "TRK-1"),
        Orders::Events::OrderDelivered.new(order_id: "7", **CUSTOMER, total: { amount_cents: 3870, currency: "EUR" }),
        Orders::Events::OrderRefunded.new(order_id: "7", **CUSTOMER, total: { amount_cents: 3870, currency: "EUR" }),
        Orders::Events::OrderCancelled.new(order_id: "7", **CUSTOMER, reason: "customer")
      ].each { |event| NotifyCustomerJob.perform_now(publish(event)) }

      assert_equal %w[ cancelled delivered placed refunded shipped ], Api.for_order("7").map(&:kind).sort
    end

    test "a notice about something that happened over an hour ago is not sent" do
      event = travel(-2.hours) { publish(placed_v2) }
      clear_enqueued_jobs

      NotifyCustomerJob.perform_now(event)

      assert_empty Api.for_order("7")
    end
  end
end
