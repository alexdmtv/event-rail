module Loyalty
  module TestSupport
    def self.points(order_id) = Entry.where(order_id: order_id.to_s).sum(:points)
  end
end
