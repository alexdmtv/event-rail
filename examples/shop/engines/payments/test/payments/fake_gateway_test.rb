require "test_helper"

module Payments
  class FakeGatewayTest < ActiveSupport::TestCase
    test "it approves every call" do
      gateway = Gateway::Fake.new

      assert_match(/\Aauth_/, gateway.authorize(idempotency_key: "k", amount_cents: 100, currency: "EUR"))
      assert_nil gateway.capture(idempotency_key: "k", authorization_code: "a", amount_cents: 100)
      assert_nil gateway.void(idempotency_key: "k", authorization_code: "a")
      assert_nil gateway.refund(idempotency_key: "k", authorization_code: "a", amount_cents: 100)
    end
  end
end
