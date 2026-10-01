module Notifications
  # What other modules' tests need of Notifications: the kinds of message sent about an order,
  # sorted. It lives with Notifications, so it may use Notifications' models; it is outside
  # the load paths, so only tests can load it.
  module TestSupport
    def self.kinds(order_id) = Notification.where(order_id: order_id.to_s).pluck(:kind).sort
  end
end
