module Payments
  # The card issuer declined the authorization.
  class Declined < Error
    include Platform::FailedPrecondition
  end
end
