module Orders
  # The shop's deadlines, enforced every minute: a placed order not confirmed within two
  # minutes, and a confirmed order not paid within thirty, is cancelled with the reason. Retries
  # never give up on an order; only these deadlines do, and an order a job is still working on
  # when its deadline passes is left to the cancellation, which the job's next run finds.
  #
  # It inherits from ActiveJob::Base rather than Orders::ApplicationJob on purpose. A scheduled
  # scan is not part of any order's flow, so it carries no EventRail context of its own; each
  # cancellation it requests joins the flow of the order it cancels.
  class DeadlineSweepJob < ActiveJob::Base
    queue_as :orders

    def perform = Order.cancel_overdue
  end
end
