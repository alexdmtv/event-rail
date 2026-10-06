require "test_helper"

# How a request and the domain events it causes appear in the structured event log.
class ObservabilityTest < ActionDispatch::IntegrationTest
  include ShopHelpers

  setup { stock_shelves }

  test "an error answered to a request is reported with the request's flow" do
    event = assert_event_reported("platform.error_reported", payload: { category: "InvalidArgument", expected: true }) do
      post "/carts", params: { items: [] }, as: :json
    end

    assert_response :unprocessable_content
    assert_equal({ request_id: response.request.request_id, correlation_id: response.request.request_id }, event[:context])
  end

  test "a domain event staged by a request appears with its type and the request's correlation" do
    event = assert_event_reported("event_rail.staged", payload: { event_type: "orders.order_placed" }) { checkout }

    assert_equal 1, event[:payload][:subscriber_count]
    assert event[:payload][:correlation_id]
  end

  test "a subscriber handling a domain event appears with its job" do
    checkout
    assert_event_reported("event_rail.subscriber_performed", payload: { event_type: "orders.order_placed", job_class: "Notifications::NotifyCustomerJob" }) do
      perform_enqueued_jobs(only: ->(job) { job.fetch(:job).name == "Notifications::NotifyCustomerJob" })
    end
  end
end
