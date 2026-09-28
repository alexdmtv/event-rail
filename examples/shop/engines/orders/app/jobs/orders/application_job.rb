module Orders
  class ApplicationJob < Platform::ApplicationJob
    queue_as :orders
  end
end
