module Loyalty
  # What the developer console shows of Loyalty.
  module Api
    class << self
      def balance(customer_id) = Loyalty::Entry.where(customer_id: customer_id).sum(:points)

      # Net points an order earned: its award less any revocation.
      def points_for_orders(order_ids) = Loyalty::Entry.where(order_id: order_ids.map(&:to_s)).group(:order_id).sum(:points)
    end
  end
end
