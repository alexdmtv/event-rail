module Orders
  # Keeps every step of an order in the order's own flow, so everything that happens to it
  # shares the correlation its checkout started and the console can show it as one tree.
  #
  # Inside a job that already carries EventRail's context -- a subscriber reacting to
  # Payments, say -- the step is already in the flow. A step started from outside one -- the
  # console, the simulator, the expiry scan -- joins the order's flow explicitly. That gives
  # it lineage only: outside a job EventRail derives no event identity, so a step that must
  # publish the same event when repeated hands the publication to a job enqueued under an ID
  # of its own (see Orders::Cancellation).
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
