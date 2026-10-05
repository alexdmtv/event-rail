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

    test "a repeated idempotency key gets the same authorization, as at a real provider" do
      gateway = Gateway::Fake.new
      authorize = ->(key) { gateway.authorize(idempotency_key: key, amount_cents: 100, currency: "EUR") }

      assert_equal authorize.("k"), authorize.("k")
      assert_not_equal authorize.("k"), authorize.("other")
    end
  end
end
