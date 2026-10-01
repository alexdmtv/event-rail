module Notifications
  # What may be read of Notifications: the messages sent about an order.
  module Api
    Notification = Data.define(:kind, :order_id, :customer_email, :subject, :body, :created_at)

    class << self
      def for_order(order_id) = Notifications::Notification.where(order_id: order_id.to_s).order(:created_at).map { |notification| value(notification) }

      private
        def value(notification)
          Notification.new(**notification.slice(:kind, :order_id, :customer_email, :subject, :body, :created_at).symbolize_keys)
        end
    end
  end
end
