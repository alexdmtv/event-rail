module Fulfillment
  class ApplicationJob < Platform::ApplicationJob
    queue_as :fulfillment
  end
end
