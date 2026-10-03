module Notifications
  module TestSupport
    def self.kinds(order_id) = Notification.where(order_id: order_id.to_s).pluck(:kind).sort
  end
end
