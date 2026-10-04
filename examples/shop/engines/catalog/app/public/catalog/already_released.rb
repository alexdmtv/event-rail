module Catalog
  class AlreadyReleased < Error
    include Platform::FailedPrecondition
  end
end
