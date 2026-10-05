require "test_helper"

module Fulfillment
  class CarrierTest < ActiveSupport::TestCase
    test "a carrier the environment does not name is refused, not faked" do
      chosen = Rails.configuration.fulfillment.carrier
      Rails.configuration.fulfillment.carrier = nil
      Carrier.adapter = nil

      assert_raises(ArgumentError) { Carrier.current }
    ensure
      Rails.configuration.fulfillment.carrier = chosen
    end
  end
end
