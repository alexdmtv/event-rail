module Orders
  # A cart being placed holds a product the shop no longer sells. Catalog's own UnknownProduct
  # is a record not found; to Orders' caller it is a cart it can no longer place as it is.
  class UnknownProduct < Error
    include Platform::InvalidArgument
  end
end
