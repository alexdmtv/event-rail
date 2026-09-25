module Orders
  module Events
    # An order was accepted at checkout: its stock is reserved and its payment authorized.
    #
    # Version 2. Version 1 carried the total as an integer `total_cents`; version 2 carries a
    # Money with its currency. Retyping a field breaks every reader, which is what a new
    # version is for: see OrderPlacedV1 for how both are handled while old messages drain.
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
