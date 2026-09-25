module Orders
  # Keeps every step of an order in the order's own flow, so everything that happens to it
  # shares the correlation its checkout started and the console can show it as one tree.
  #
  # Inside a job that already carries EventRail's context -- a subscriber reacting to
  # Payments, say -- the step is already in the flow. A step started from outside one -- the
  # console, the simulator, the expiry scan -- joins the order's flow explicitly. Its message
  # ID is derived from the step, so repeating the same step derives the same event
  # identities.
  module Flow
    def self.continue(order, step:, &block)
      if EventRail::Current.correlation_id
        yield
      else
        EventRail.with_context(message_id: "#{step}-#{order.id}", correlation_id: order.correlation_id, &block)
      end
    end
  end
end
