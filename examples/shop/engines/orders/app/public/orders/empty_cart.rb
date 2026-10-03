module Orders
  class EmptyCart < Error
    include Platform::InvalidArgument
  end
end
