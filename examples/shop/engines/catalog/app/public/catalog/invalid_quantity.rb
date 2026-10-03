module Catalog
  class InvalidQuantity < Error
    include Platform::InvalidArgument
  end
end
