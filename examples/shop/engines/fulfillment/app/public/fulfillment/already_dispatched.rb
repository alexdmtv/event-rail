module Fulfillment
  # The carrier already has the parcel.
  class AlreadyDispatched < Error
    include Platform::FailedPrecondition
  end
end
