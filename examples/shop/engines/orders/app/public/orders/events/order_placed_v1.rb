module Orders
  module Events
    # No longer published. Keep it registered until no version 1 message can still be queued:
    # without it, those fail to deserialize.
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
