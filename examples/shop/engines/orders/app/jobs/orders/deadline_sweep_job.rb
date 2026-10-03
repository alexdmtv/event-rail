module Orders
  # Not an Orders::ApplicationJob on purpose: the sweep belongs to no order's flow, so it carries
  # no EventRail context, and each cancellation it requests joins its own order's flow.
  class DeadlineSweepJob < ActiveJob::Base
    queue_as :orders

    def perform = Order.cancel_overdue
  end
end
