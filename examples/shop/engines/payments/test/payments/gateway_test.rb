require "test_helper"

module Payments
  class GatewayTest < ActiveSupport::TestCase
    test "the gateway is the one the environment chose, built once" do
      assert_kind_of Gateway::Fake, Gateway.current
      assert_same Gateway.current, Gateway.current
    end

    test "a gateway the environment does not name is refused, not faked" do
      chosen = Rails.configuration.payments.gateway
      Rails.configuration.payments.gateway = :stripe
      Gateway.adapter = nil

      assert_raises(ArgumentError) { Gateway.current }
    ensure
      Rails.configuration.payments.gateway = chosen
    end

    test "every call to the provider is measured by operation and outcome, whichever adapter answers it" do
      Gateway.adapter = ScriptedGateway.new(authorize: [ :ok, :refuse, :timeout ])
      authorize = ->(reference) { Api.authorize(reference:, amount_cents: 4990, currency: "EUR") }

      authorize.("ref-1")
      assert_raises(Declined) { authorize.("ref-2") }
      assert_raises(Unavailable) { authorize.("ref-3") }

      assert_equal [ { operation: :authorize, outcome: "failed" }, { operation: :authorize, outcome: "refused" }, { operation: :authorize, outcome: "succeeded" } ],
        recorded(Yabeda.payments.gateway_call_duration_seconds).keys.sort_by { |tags| tags[:outcome] }
    end

    test "every call to the provider is a span, with its operation and outcome" do
      Gateway.adapter = ScriptedGateway.new(capture: [ :refuse ])

      assert_raises(Gateway::Refused) { Gateway.call(:capture, idempotency_key: "capture-1", authorization_code: "auth", amount_cents: 4990) }

      span = Platform::Traces.exporter.finished_spans.find { |it| it.name == "call_gateway.payments" }
      assert_equal({ "operation" => "capture", "outcome" => "refused" }, span.attributes.slice("operation", "outcome"))
    end
  end
end
