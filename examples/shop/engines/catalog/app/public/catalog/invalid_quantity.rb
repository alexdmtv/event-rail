module Catalog
  # A reservation asked for a quantity that is not a positive whole number.
  class InvalidQuantity < Error
    include Platform::InvalidArgument
  end
end
