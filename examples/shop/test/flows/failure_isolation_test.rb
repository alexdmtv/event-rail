require_relative "flow_test_case"

class FailureIsolationTest < FlowTestCase
  test "a Loyalty that fails every attempt leaves every order, payment and shipment untouched" do
    Platform::FaultSettings.force_failures("Loyalty::AwardPointsJob", 100)

    order, published = place_and_settle

    assert_equal "delivered", order.state
    assert_equal "captured", Payments::Api.payment(order.reference).state
    assert_equal "delivered", Fulfillment::Api.shipment(order.reference).state
    assert_equal %w[ delivered placed shipped ], notified_kinds(order)
    assert_equal 0, points(order)
    assert_equal [ "Loyalty::AwardPointsJob" ], @job_failures.map(&:job_class).uniq
    assert_one_flow(order, published)
  end

  test "a subscriber told to fail three times retries alone and then succeeds" do
    Platform::FaultSettings.force_failures("Loyalty::AwardPointsJob", 3)

    order = nil
    retries = retries_by_job { order, = place_and_settle }

    assert_equal({ "Loyalty::AwardPointsJob" => 3 }, retries)
    assert_equal 38, points(order)
    assert_empty @job_failures
  end
end
