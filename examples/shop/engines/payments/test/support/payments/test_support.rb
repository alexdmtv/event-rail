require_relative "scripted_gateway"

module Payments
  # What other modules' tests and the host's may use of Payments: the provider's behaviour, set
  # in Payments' terms, and readers that answer with values, never records, so Payments can change
  # inside without breaking anyone else's tests. Configuring the provider returns nil; readers
  # answer a mapped symbol, an amount in cents or true or false.
  module TestSupport
    MONEY = { "authorized" => :held, "captured" => :captured, "voided" => :voided, "refunded" => :refunded }.freeze
    REQUESTS = { "capture" => :capture, "void" => :void, "refund" => :refund }.freeze

    class << self
      # The provider refuses one more request of that kind: :authorize (the card is declined),
      # :capture, :void or :refund. Anything not set this way succeeds.
      def provider_refuses(operation) = provider.script(operation, :refuse).then { nil }

      # The provider doesn't answer that many more requests of that kind; Payments retries them.
      def provider_times_out(operation, times: 1) = provider.script(operation, *[ :timeout ] * times).then { nil }

      # The provider answers no request of that kind, however often Payments retries, until it
      # answers again.
      def provider_stops_answering(operation) = provider.stop_answering(operation).then { nil }
      def provider_answers_again(operation) = provider.answer_again(operation).then { nil }

      # The provider answers everything Payments has asked it and not heard back on, as set above,
      # and Payments announces the outcomes; Payments' own jobs do the work.
      def provider_answers = Platform::TestSupport::Worker.perform_queued(CallProviderJob).then { nil }

      # What a test set the provider to do and never happened, as { operation => steps }; empty
      # when every fault it set was met. The host's test helper checks it after every test; a test that starts the provider over in
      # its middle checks it first.
      def unused_provider_faults = Gateway.current.is_a?(ScriptedGateway) ? Gateway.current.unused : {}

      # Back to the provider the environment chose.
      def reset_provider = Gateway.adapter = nil

      # Where the money for the reference stands: nil (no payment), :held, :captured, :voided or :refunded.
      def money_status(reference) = payment(reference)&.state&.then { |state| MONEY.fetch(state) }

      # The amount held, captured or given back, in cents; nil with no payment.
      def money_amount(reference) = payment(reference)&.amount_cents

      # What Payments has asked the provider and not yet heard back on: :capture, :void, :refund or nil.
      def pending_request(reference) = outstanding_call(reference)&.kind&.then { |kind| REQUESTS.fetch(kind) }

      # Whether the money is to be given back once whatever is pending is answered.
      def release_requested?(reference) = payment(reference)&.release_requested_at.present?

      private
        def provider = Gateway.current.is_a?(ScriptedGateway) ? Gateway.current : ScriptedGateway.new.tap { |gateway| Gateway.adapter = gateway }
        def payment(reference) = Payment.find_by(reference: reference)
        def outstanding_call(reference) = payment(reference)&.provider_calls&.outstanding&.first
    end
  end
end
