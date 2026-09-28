module Orders
  # The order has shipped, and can only be returned.
  class NotCancellable < Error
    include Platform::FailedPrecondition
  end
end
