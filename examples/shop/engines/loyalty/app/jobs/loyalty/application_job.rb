module Loyalty
  class ApplicationJob < Platform::ApplicationJob
    queue_as :loyalty
  end
end
