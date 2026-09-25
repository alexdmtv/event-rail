module Loyalty
  class ApplicationJob < Platform::ApplicationJob
    queue_as :loyalty

    # Points are owed to the customer, so a failing Loyalty keeps trying -- on its own
    # schedule, without holding up anything else in the shop.
    retry_on StandardError, wait: 2.seconds, attempts: 10
  end
end
