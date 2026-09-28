module Orders
  # A quantity that is not a whole number above zero.
  class InvalidQuantity < Error
    include Platform::InvalidArgument
  end
end
