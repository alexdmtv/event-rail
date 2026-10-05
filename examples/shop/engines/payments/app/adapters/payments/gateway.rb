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
      # A test may plug in another adapter; nil goes back to the environment's choice.
      attr_writer :adapter

      # Built on first use, so a reload, which replaces this module, builds it again.
      def current = @adapter ||= build(Rails.configuration.payments.gateway)

      private
        def build(name)
          case name
          when :fake then Fake.new
          else raise ArgumentError, "config.payments.gateway names no payment gateway: #{name.inspect}"
          end
        end
    end
  end
end
