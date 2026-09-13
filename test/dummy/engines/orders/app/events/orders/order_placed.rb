module Orders
  class OrderPlaced < EventRail::Event
    event_type "orders.order_placed"
    version 1
    default_source "event_rail.orders"

    attribute :order_id, :string
  end
end
