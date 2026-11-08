require_relative "scripted_gateway"

module Payments
  # What other modules' tests and the host's may use of Payments: the provider's behaviour, set
  # in Payments' terms, and readers that answer with values, never records, so Payments can change
  # inside without breaking anyone else's tests.
  module TestSupport
    MONEY = { "authorized" => :held, "captured" => :captured, "voided" => :voided, "refunded" => :refunded }.freeze

    # Back to the gateway the environment chose.
    def self.reset_gateway = Gateway.adapter = nil

    # The provider refuses the next request of that kind: :authorize (the card is declined),
    # :capture, :void or :refund. Anything not set this way succeeds.
    def self.provider_refuses(operation) = provider.script(operation, :refuse)

    # The provider doesn't answer the next requests of that kind; Payments retries them.
    def self.provider_times_out(operation, times: 1) = provider.script(operation, *[ :timeout ] * times)

    # Where the money for the reference stands: nil (no payment), :held, :captured, :voided or :refunded.
    def self.money_status(reference) = MONEY[payment(reference)&.state]

    # What Payments has asked the provider and not yet heard back on: :capture, :void, :refund or nil.
    def self.pending_request(reference) = outstanding_call(reference)&.kind&.to_sym

    # Whether the money is to be given back once whatever is pending is answered.
    def self.release_requested?(reference) = payment(reference)&.release_requested_at.present?

    def self.provider = Gateway.current.is_a?(ScriptedGateway) ? Gateway.current : ScriptedGateway.new.tap { |gateway| Gateway.adapter = gateway }
    def self.payment(reference) = Payment.find_by(reference: reference)
    def self.outstanding_call(reference) = payment(reference)&.provider_calls&.outstanding&.first
    private_class_method :provider, :payment, :outstanding_call
  end
end
