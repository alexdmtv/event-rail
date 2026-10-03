module Payments
  # The provider seam: an adapter answers `authorize`, `capture`, `void` and `refund`, and
  # raises Refused or TemporaryFailure.
  module Gateway
    # A definitive refusal; retrying will not help.
    class Refused < StandardError
      include Platform::FailedPrecondition
    end

    # No answer this time (a timeout, a 503); retrying may help.
    class TemporaryFailure < StandardError
      include Platform::Unavailable
    end

    class << self
      attr_writer :adapter

      def current = @adapter || Fake.new
    end
  end
end
