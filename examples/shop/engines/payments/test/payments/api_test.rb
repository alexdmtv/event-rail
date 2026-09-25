require "test_helper"

module Payments
  class ApiTest < ActiveSupport::TestCase
    def authorize(reference = "ref-1") = Api.authorize(reference: reference, amount_cents: 4990, currency: "EUR")

    test "an approved authorization holds the amount and nothing is captured yet" do
      payment = authorize

      assert_equal "authorized", payment.state
      assert_nil Payments::Payment.find_by!(reference: "ref-1").captured_at
    end

    test "authorizing the same reference twice holds the amount once" do
      Gateway.adapter = gateway = ScriptedGateway.new
      2.times { authorize }

      assert_equal 1, gateway.calls[:authorize]
      assert_equal 1, Payments::Payment.count
    end

    test "a declined authorization raises and records nothing" do
      Gateway.adapter = ScriptedGateway.new(authorize: [ :refuse ])

      assert_raises(Api::Declined) { authorize }
      assert_equal 0, Payments::Payment.count
    end

    test "an unreachable provider at authorization is reported as unavailable" do
      Gateway.adapter = ScriptedGateway.new(authorize: [ :timeout ])

      assert_raises(Api::Unavailable) { authorize }
    end

    test "capture returns before the provider is contacted and reports its outcome as an event" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new

      Api.capture(reference: "ref-1")
      assert_equal 0, gateway.calls[:capture]

      published = record_publications { perform_enqueued_jobs }
      assert_equal [ "payments.payment_captured" ], published.map(&:event_type)
      assert_equal "captured", Api.payment("ref-1").state
    end

    test "a repeated capture command captures once and reports again under the same identity" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new

      first = record_publications { Api.capture(reference: "ref-1"); perform_enqueued_jobs }
      second = record_publications { Api.capture(reference: "ref-1"); perform_enqueued_jobs }

      assert_equal 1, gateway.calls[:capture]
      assert_equal first.map(&:event_id), second.map(&:event_id)
    end

    test "temporary provider failures are retried until the capture succeeds" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new(capture: [ :timeout, :timeout, :ok ])

      published = record_publications { perform_enqueued_jobs { Api.capture(reference: "ref-1") } }

      assert_equal 3, gateway.calls[:capture]
      assert_equal [ "payments.payment_captured" ], published.map(&:event_type)
    end

    test "a refused capture is reported as a failed capture" do
      authorize
      Gateway.adapter = ScriptedGateway.new(capture: [ :refuse ])

      published = record_publications { perform_enqueued_jobs { Api.capture(reference: "ref-1") } }

      assert_equal [ "payments.capture_failed" ], published.map(&:event_type)
      assert_equal "capture_failed", Api.payment("ref-1").state
    end

    test "a provider that never answers ends as a failed capture" do
      authorize
      Gateway.adapter = ScriptedGateway.new(capture: [ :timeout ] * 5)

      published = record_publications { perform_enqueued_jobs { Api.capture(reference: "ref-1") } }

      assert_equal [ "payments.capture_failed" ], published.map(&:event_type)
    end

    test "void releases an uncaptured authorization" do
      authorize

      published = record_publications { perform_enqueued_jobs { Api.void(reference: "ref-1") } }

      assert_equal [ "payments.authorization_voided" ], published.map(&:event_type)
      assert_equal "voided", Api.payment("ref-1").state
    end

    test "void leaves a captured payment alone" do
      authorize
      perform_enqueued_jobs { Api.capture(reference: "ref-1") }

      published = record_publications { perform_enqueued_jobs { Api.void(reference: "ref-1") } }

      assert_empty published
      assert_equal "captured", Api.payment("ref-1").state
    end

    test "a refund returns captured money and reports it" do
      authorize
      perform_enqueued_jobs { Api.capture(reference: "ref-1") }

      published = record_publications { perform_enqueued_jobs { Api.refund(reference: "ref-1") } }

      assert_equal [ "payments.refund_issued" ], published.map(&:event_type)
      assert_equal "refunded", Api.payment("ref-1").state
    end

    test "a refused refund is reported as a failed refund" do
      authorize
      perform_enqueued_jobs { Api.capture(reference: "ref-1") }
      Gateway.adapter = ScriptedGateway.new(refund: [ :refuse ])

      published = record_publications { perform_enqueued_jobs { Api.refund(reference: "ref-1") } }

      assert_equal [ "payments.refund_failed" ], published.map(&:event_type)
    end

    test "payments are looked up for many references at once" do
      authorize("ref-1")
      authorize("ref-2")

      payments = Api.payments(%w[ ref-1 ref-2 ref-3 ])

      assert_equal %w[ ref-1 ref-2 ], payments.keys.sort
      assert_equal "authorized", payments["ref-2"].state
    end
  end
end
