require "test_helper"

# How a request and the domain events it causes appear in the structured event log.
class ObservabilityTest < ActionDispatch::IntegrationTest
  test "an error answered to a request is reported with the request's flow" do
    event = assert_event_reported("platform.error_reported", payload: { category: "InvalidArgument", expected: true }) do
      post "/carts", params: { items: [] }, as: :json
    end

    assert_response :unprocessable_content
    request_id = response.request.request_id
    assert_equal({ request_id:, message_id: request_id, correlation_id: request_id }, event[:context])
  end

  test "a domain event staged by a request appears with its type and the request's correlation" do
    event = assert_event_reported("event_rail.staged", payload: { event_type: "orders.order_placed" }) { Orders::TestSupport.checkout }

    assert_operator event[:payload][:subscriber_count], :>, 0
    assert event[:payload][:correlation_id]
  end

  test "a request is traced from the server's side" do
    post "/carts", params: { items: [] }, as: :json

    assert Platform::Traces.exporter.finished_spans.any? { |span| span.kind == :server }
  end

  test "EventRail's work is traced, and its spans stay out of the event log" do
    staged = OpenTelemetry.tracer_provider.tracer("test").in_span("request", kind: :server) do
      assert_event_reported("event_rail.staged", payload: { event_type: "orders.order_placed" }) { Orders::TestSupport.checkout }
    end

    assert_includes Platform::Traces.exporter.finished_spans.map(&:name), "stage.event_rail"
    assert_empty staged[:payload].keys.grep(/\A__/)
  end

  test "the outbox's health is answered without the queue, and fails once a job has waited too long" do
    get "/up/outbox"
    assert_response :ok
    assert_equal({ "staged_jobs" => 0, "oldest_age_seconds" => 0, "parked" => 0 }, response.parsed_body)

    Platform::StagedJob.create!(job_id: "j-1", job_class: "ShipOrderJob", payload: {}, created_at: (Platform::StagedJob::STUCK_AFTER + 1.minute).ago)
    get "/up/outbox"
    assert_response :service_unavailable
    assert_equal 1, response.parsed_body["staged_jobs"]

    Platform::StagedJob.sole.update!(parked_at: Time.current)
    get "/up/outbox"
    assert_response :ok, "a parked job was reported, and doesn't hold the check failing"
    assert_equal({ "staged_jobs" => 0, "oldest_age_seconds" => 0, "parked" => 1 }, response.parsed_body)
  end

  test "a request continues no trace an untrusted caller sends, and links to it instead" do
    sent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
    post "/carts", params: { items: [] }, as: :json, headers: { "traceparent" => sent, "baggage" => "customer=ada" }

    server = Platform::Traces.exporter.finished_spans.find { |span| span.kind == :server }
    assert_not_equal "0af7651916cd43dd8448eb211c80319c", server.hex_trace_id
    assert_equal "0af7651916cd43dd8448eb211c80319c", server.links.sole.span_context.hex_trace_id
  end

  test "a request from a trusted service continues its trace" do
    Rails.configuration.platform.trusted_trace_source = ->(_env) { true }
    post "/carts", params: { items: [] }, as: :json, headers: { "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" }

    server = Platform::Traces.exporter.finished_spans.find { |span| span.kind == :server }
    assert_equal "0af7651916cd43dd8448eb211c80319c", server.hex_trace_id
    assert_equal "b7ad6b7169203331", server.hex_parent_span_id
  ensure
    Rails.configuration.platform.trusted_trace_source = ->(_env) { false }
  end
end
