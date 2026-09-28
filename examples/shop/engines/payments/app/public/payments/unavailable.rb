module Payments
  # The payment provider did not answer; the caller may try again.
  class Unavailable < Error
    include Platform::Unavailable
  end
end
