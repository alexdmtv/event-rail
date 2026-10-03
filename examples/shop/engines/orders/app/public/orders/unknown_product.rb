module Orders
  # Catalog's UnknownProduct is a not-found; to Orders' caller, a cart it can no longer place is
  # an invalid argument.
  class UnknownProduct < Error
    include Platform::InvalidArgument
  end
end
