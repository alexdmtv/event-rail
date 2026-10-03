module Catalog
  class UnknownProduct < Error
    include Platform::NotFound
  end
end
