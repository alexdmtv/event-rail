module Orders
  # A scheduled job, not a step: no retries of its own (an Orders::ApplicationJob would retry).
  # Each run is a flow of its own, which the cancellations it requests share.
  class DeadlineSweepJob < ActiveJob::Base
    include EventRail::JobContext

    queue_as :orders

    def perform = Order.cancel_overdue
  end
end
