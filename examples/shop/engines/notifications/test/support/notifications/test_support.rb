module Notifications
  # What other modules' tests and the host's may use of Notifications: readers that answer with
  # values, never records.
  module TestSupport
    KINDS = { "placed" => :placed, "cancelled" => :cancelled, "shipped" => :shipped, "delivered" => :delivered, "refunded" => :refunded }.freeze

    # What the customer was told about the order, sorted: :placed, :cancelled, :shipped, :delivered, :refunded.
    def self.kinds(order_id) = Notification.where(order_id: order_id.to_s).pluck(:kind).map { |kind| KINDS.fetch(kind) }.sort
  end
end
