module Loyalty
  # What other modules' tests and the host's may use of Loyalty: readers that answer with values,
  # never records.
  module TestSupport
    # The points the order earned, net of any it gave back.
    def self.points(order_id) = Entry.where(order_id: order_id.to_s).sum(:points)
  end
end
