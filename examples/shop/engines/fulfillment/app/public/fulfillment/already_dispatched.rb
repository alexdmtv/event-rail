module Fulfillment
  class AlreadyDispatched < Error
    include Platform::FailedPrecondition
  end
end
