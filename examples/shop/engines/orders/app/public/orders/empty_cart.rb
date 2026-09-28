module Orders
  # A cart with nothing in it cannot be ordered.
  class EmptyCart < Error
    include Platform::InvalidArgument
  end
end
