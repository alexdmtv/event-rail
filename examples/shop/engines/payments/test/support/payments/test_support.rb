require_relative "scripted_gateway"

module Payments
  module TestSupport
    def self.payment(reference) = Payment.find_by(reference: reference)

    # Plugs in a gateway answering each call as scripted, and returns it to count the calls.
    def self.scripted_gateway(**script) = ScriptedGateway.new(**script).tap { |gateway| Gateway.adapter = gateway }

    # Back to the gateway the environment chose.
    def self.reset_gateway = Gateway.adapter = nil
  end
end
