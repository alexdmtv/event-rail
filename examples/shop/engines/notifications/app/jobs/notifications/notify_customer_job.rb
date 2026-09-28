module Notifications
  # One subscriber for every customer-facing order fact. It subscribes to both versions of
  # OrderPlaced: the shop publishes version 2, and a version 1 delivery still queued from
  # before the upgrade is handled rather than lost.
  class NotifyCustomerJob < ApplicationJob
    subscribes_to Orders::Events::OrderPlaced, Orders::Events::OrderPlacedV1,
      Orders::Events::OrderShipped, Orders::Events::OrderDelivered,
      Orders::Events::OrderCancelled, Orders::Events::OrderRefunded

    def perform(event) = Notification.send_for(event)
  end
end
