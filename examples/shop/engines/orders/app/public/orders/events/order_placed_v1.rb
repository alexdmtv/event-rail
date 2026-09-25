module Orders
  module Events
    # Version 1 of OrderPlaced, no longer published but still registered.
    #
    # When version 2 was introduced, version 1 messages were still sitting in the queue:
    # subscriber jobs enqueued by the previous release, not yet performed. Deleting this
    # class would make every one of them fail to deserialize. So the upgrade ran in three
    # releases:
    #
    #   1. Subscribers learned to read both versions (they subscribe to both classes).
    #   2. The publisher switched to version 2.
    #   3. Once no version 1 message could still be in flight, this class and the subscribers'
    #      version 1 handling can go.
    #
    # The example stays between steps 2 and 3, so both paths are visible. The queue refers to
    # an event by its type and version, never by class name, so the old class could be
    # renamed from OrderPlaced to OrderPlacedV1 without breaking anything queued.
    class OrderPlacedV1 < EventRail::Event
      event_type "orders.order_placed"
      version 1
      default_source "shop.orders"
      identity_by :order_id

      attribute :order_id, :string
      attribute :customer_id, :string
      attribute :customer_name, :string
      attribute :customer_email, :string
      attribute :total_cents, :integer
      attribute :line_items, LineItem, array: true
    end
  end
end
