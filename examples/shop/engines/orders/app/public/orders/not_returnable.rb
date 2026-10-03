module Orders
  class NotReturnable < Error
    include Platform::FailedPrecondition
  end
end
