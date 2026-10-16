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

    test "every call to the provider is a span, with its operation and outcome; a refusal is an answer, a timeout a failure" do
      Gateway.adapter = ScriptedGateway.new(capture: [ :refuse, :timeout ])

      OpenTelemetry.tracer_provider.tracer("test").in_span("job", kind: :consumer) do
        assert_raises(Gateway::Refused) { Gateway.call(:capture, idempotency_key: "capture-1", authorization_code: "auth", amount_cents: 4990) }
        assert_raises(Gateway::TemporaryFailure) { Gateway.call(:capture, idempotency_key: "capture-2", authorization_code: "auth", amount_cents: 4990) }
      end

      refused, failed = Platform::Traces.exporter.finished_spans.select { |it| it.name == "call_gateway.payments" }
      assert_equal({ "operation" => "capture", "outcome" => "refused" }, refused.attributes.slice("operation", "outcome"))
      assert_equal OpenTelemetry::Trace::Status::UNSET, refused.status.code
      assert_equal "failed", failed.attributes["outcome"]
      assert_equal OpenTelemetry::Trace::Status::ERROR, failed.status.code
    end
  end
end
