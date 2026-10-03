module Orders
  module Events
    class OrderCancelled < EventRail::Event
      event_type "orders.order_cancelled"
      version 1
      default_source "shop.orders"
      identity_by :order_id

      attribute :order_id, :string
      attribute :customer_id, :string
      attribute :customer_name, :string
      attribute :customer_email, :string
      attribute :reason, :string

      validates :order_id, :customer_id, :customer_email, presence: true
    end
  end
end
