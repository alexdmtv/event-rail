module Payments
  class Unavailable < Error
    include Platform::Unavailable
  end
end
