module Payments
  class ApplicationJob < Platform::ApplicationJob
    queue_as :payments
  end
end
