module Orders
  # The cart names a product the shop does not sell. Catalog's own UnknownProduct is a record
  # not found; to Orders' caller it is a cart it may not fill that way.
  class UnknownProduct < Error
    include Platform::InvalidArgument
  end
end
