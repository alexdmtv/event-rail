module Loyalty
  # What other modules' tests need of Loyalty: the net points an order earned, its award less
  # any revocation. It lives with Loyalty, so it may use Loyalty's models; it is outside the
  # load paths, so only tests can load it.
  module TestSupport
    def self.points(order_id) = Entry.where(order_id: order_id.to_s).sum(:points)
  end
end
