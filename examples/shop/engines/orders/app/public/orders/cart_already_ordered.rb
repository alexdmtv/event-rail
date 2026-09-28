module Orders
  # A cart that became an order takes no more items.
  class CartAlreadyOrdered < Error
    include Platform::FailedPrecondition
  end
end
