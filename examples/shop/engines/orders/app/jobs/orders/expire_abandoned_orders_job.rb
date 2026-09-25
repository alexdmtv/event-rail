module Orders
  # The business rule for checkouts nobody finished: an order still placed and unpaid 30
  # minutes after checkout is cancelled, releasing its stock and its card hold. It covers a
  # customer who saw a checkout error and never retried, and a payment that never settled.
  #
  # It inherits from ActiveJob::Base rather than Orders::ApplicationJob on purpose. A
  # scheduled scan is not part of any order's flow, so it carries no EventRail context of its
  # own; each cancellation it makes joins the flow of the order it cancels.
  class ExpireAbandonedOrdersJob < ActiveJob::Base
    queue_as :orders

    def perform
      Order.abandoned.find_each do |order|
        Api.cancel(order.id, reason: "abandoned")
      rescue Api::NotCancellable
        next # it moved on while the scan ran
      end
    end
  end
end
