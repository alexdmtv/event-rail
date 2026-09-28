module Orders
  # A delivery was heard before the dispatch that must precede it. EventRail promises no
  # order between deliveries, and the workers run in parallel, so this happens; the
  # subscriber raises this to be retried once the dispatch has been recorded, rather than
  # succeed without effect and lose the delivery.
  class NotYetShipped < StandardError
    include Platform::Aborted
  end
end
