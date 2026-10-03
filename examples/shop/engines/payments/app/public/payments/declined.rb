module Payments
  class Declined < Error
    include Platform::FailedPrecondition
  end
end
