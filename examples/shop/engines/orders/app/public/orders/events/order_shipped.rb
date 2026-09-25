module Orders
  module Events
    # The order left the warehouse.
    class OrderShipped < EventRail::Event
      event_type "orders.order_shipped"
      version 1
      default_source "shop.orders"
      identity_by :order_id

      attribute :order_id, :string
      attribute :customer_id, :string
      attribute :customer_name, :string
      attribute :customer_email, :string
      attribute :tracking_code, :string

      validates :order_id, :customer_id, :customer_email, presence: true
    end
  end
end
