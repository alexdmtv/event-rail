module Orders
  class ApplicationJob < Platform::ApplicationJob
    queue_as :orders

    # Orders' jobs move the order's lifecycle on, so a failed one is tried again rather than
    # leaving an order stuck. Every one of them is safe to repeat.
    retry_on StandardError, wait: 2.seconds, attempts: 10
  end
end
