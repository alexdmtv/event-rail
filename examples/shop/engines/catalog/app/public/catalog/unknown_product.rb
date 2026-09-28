module Catalog
  # No product has the SKU asked for.
  class UnknownProduct < Error
    include Platform::NotFound
  end
end
