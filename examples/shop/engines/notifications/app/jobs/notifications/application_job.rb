module Notifications
  class ApplicationJob < Platform::ApplicationJob
    queue_as :notifications
  end
end
