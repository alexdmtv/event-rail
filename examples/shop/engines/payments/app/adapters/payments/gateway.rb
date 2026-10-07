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

      # Every call to the provider goes through here, whichever adapter answers it, so each is
      # timed, counted and traced the same way (call_gateway.payments). A refusal is an answer,
      # not a failure, so the payload names the outcome.
      def call(operation, **arguments)
        ActiveSupport::Notifications.instrument("call_gateway.payments", operation:) do |payload|
          current.public_send(operation, **arguments).tap { payload[:outcome] = "succeeded" }
        rescue Refused
          payload[:outcome] = "refused"
          raise
        end
      end

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
