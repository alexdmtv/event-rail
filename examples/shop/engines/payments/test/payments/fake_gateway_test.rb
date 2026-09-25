require "test_helper"

module Payments
  class FakeGatewayTest < ActiveSupport::TestCase
    setup { @gateway = Gateway::Fake.new }

    def authorize = @gateway.authorize(idempotency_key: "k", amount_cents: 100, currency: "EUR")

    test "with every rate at zero it approves" do
      assert_match(/\Aauth_/, authorize)
      assert_nil @gateway.capture(idempotency_key: "k", authorization_code: "a", amount_cents: 100)
    end

    test "the console's decline rate declines authorizations" do
      Platform::FaultSettings.current.update!(authorization_decline_rate: 1.0)

      assert_raises(Gateway::Refused) { authorize }
    end

    test "the console's refusal rate refuses captures" do
      Platform::FaultSettings.current.update!(capture_refusal_rate: 1.0)

      assert_raises(Gateway::Refused) { @gateway.capture(idempotency_key: "k", authorization_code: "a", amount_cents: 100) }
    end

    test "the console's temporary failure rate makes the provider time out" do
      Platform::FaultSettings.current.update!(temporary_failure_rate: 1.0)

      assert_raises(Gateway::TemporaryFailure) { authorize }
    end
  end
end
