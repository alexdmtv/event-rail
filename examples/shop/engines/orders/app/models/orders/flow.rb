module Orders
  # Runs a step in the order's flow. A step started outside a job (a web request, the deadline
  # sweep) joins it explicitly, which gives lineage but no retries: a publication the step must
  # see through belongs in a staged job.
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
