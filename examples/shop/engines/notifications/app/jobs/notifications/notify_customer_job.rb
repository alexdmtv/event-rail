module Notifications
  # OrderPlacedV1 stays while a version 1 delivery may still be queued from before the upgrade.
  class NotifyCustomerJob < ApplicationJob
    subscribes_to Orders::Events::OrderPlaced, Orders::Events::OrderPlacedV1,
      Orders::Events::OrderShipped, Orders::Events::OrderDelivered,
      Orders::Events::OrderCancelled, Orders::Events::OrderRefunded

    def perform(event) = Notification.send_for(event)
  end
end
