module Orders
  module Events
    # A returned order was refunded in full.
    class OrderRefunded < EventRail::Event
      event_type "orders.order_refunded"
      version 1
      default_source "shop.orders"
      identity_by :order_id

      attribute :order_id, :string
      attribute :customer_id, :string
      attribute :customer_name, :string
      attribute :customer_email, :string
      attribute :total, Money

      validates :order_id, :customer_id, :customer_email, presence: true
    end
  end
end
