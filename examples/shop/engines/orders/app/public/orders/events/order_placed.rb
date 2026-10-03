module Orders
  module Events
    # Version 2 retyped the total from integer cents to Money; OrderPlacedV1 still reads version 1
    # messages that are queued.
    class OrderPlaced < EventRail::Event
      event_type "orders.order_placed"
      version 2
      default_source "shop.orders"
      identity_by :order_id

      attribute :order_id, :string
      attribute :customer_id, :string
      attribute :customer_name, :string
      attribute :customer_email, :string
      attribute :total, Money
      attribute :line_items, LineItem, array: true

      validates :order_id, :customer_id, :customer_email, :total, presence: true
    end
  end
end
