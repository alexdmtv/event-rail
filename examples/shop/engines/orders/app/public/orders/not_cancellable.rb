module Orders
  class NotCancellable < Error
    include Platform::FailedPrecondition
  end
end
