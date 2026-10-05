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
  end
end
