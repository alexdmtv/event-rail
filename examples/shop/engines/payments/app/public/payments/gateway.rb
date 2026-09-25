module Payments
  # The payment provider, as Payments sees it: the seam where an application plugs in its
  # provider, and so part of Payments' public surface. An adapter answers `authorize`,
  # `capture`, `void` and `refund`, and raises Refused or TemporaryFailure. The example
  # ships Gateway::Fake, which stays private to Payments; tests install a scripted adapter.
  module Gateway
    # The provider refused, definitively: a declined authorization, a refused capture or
    # refund. Retrying will not help.
    class Refused < StandardError; end

    # The provider could not answer this time: a timeout, a 503. Retrying is the right move.
    class TemporaryFailure < StandardError; end

    class << self
      attr_writer :adapter

      def current = @adapter || Fake.new
    end
  end
end
