module Orders
  # The order was not delivered, or its return window has closed.
  class NotReturnable < Error
    include Platform::FailedPrecondition
  end
end
