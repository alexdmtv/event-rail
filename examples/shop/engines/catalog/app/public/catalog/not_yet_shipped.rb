module Catalog
  class NotYetShipped < Error
    include Platform::Aborted
  end
end
