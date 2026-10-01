require "test_helper"

module Payments
  class ApiTest < ActiveSupport::TestCase
    def authorize(reference = "ref-1") = Api.authorize(reference: reference, amount_cents: 4990, currency: "EUR")
    def payment(reference) = Payment.find_by!(reference: reference)

    test "an approved authorization holds the amount and nothing is captured yet" do
      authorize

      assert_equal "authorized", payment("ref-1").state
      assert_nil payment("ref-1").captured_at
    end

    test "authorizing the same reference twice holds the amount once" do
      Gateway.adapter = gateway = ScriptedGateway.new
      2.times { authorize }

      assert_equal 1, gateway.calls[:authorize]
      assert_equal 1, Payments::Payment.count
    end

    test "a declined authorization raises and records nothing" do
      Gateway.adapter = ScriptedGateway.new(authorize: [ :refuse ])

      assert_raises(Declined) { authorize }
      assert_equal 0, Payments::Payment.count
    end

    test "an unreachable provider at authorization is reported as unavailable" do
      Gateway.adapter = ScriptedGateway.new(authorize: [ :timeout ])

      assert_raises(Unavailable) { authorize }
    end

    test "capture returns before the provider is contacted and reports its outcome as an event" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new

      Api.request_capture(reference: "ref-1")
      assert_equal 0, gateway.calls[:capture]

      published = record_publications { perform_enqueued_jobs }
      assert_equal [ "payments.payment_captured" ], published.map(&:event_type)
      assert_equal "captured", payment("ref-1").state
    end

    test "a repeated capture command captures once and reports once: the report was staged with the capture" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new

      first = record_publications { Api.request_capture(reference: "ref-1"); perform_enqueued_jobs }
      second = record_publications { Api.request_capture(reference: "ref-1"); perform_enqueued_jobs }

      assert_equal 1, gateway.calls[:capture]
      assert_equal [ "payments.payment_captured" ], first.map(&:event_type)
      assert_empty second
    end

    test "a capture job delivered twice captures once and reports once" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new
      Api.request_capture(reference: "ref-1")
      enqueued_jobs << enqueued_jobs.sole.dup # the relay handed it over twice

      published = record_publications { work_off_queue }

      assert_equal 1, gateway.calls[:capture]
      assert_equal [ "payments.payment_captured" ], published.map(&:event_type)
    end

    test "a second delivery of a capture, run after the payment moved on, changes nothing" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new
      Api.request_capture(reference: "ref-1")
      late = enqueued_jobs.sole.dup
      work_off_queue
      perform_enqueued_jobs { Api.request_release(reference: "ref-1") }
      assert_equal "refunded", payment("ref-1").state

      published = record_publications { enqueued_jobs << late; work_off_queue }

      assert_empty published
      assert_equal 1, gateway.calls[:capture]
      assert_equal "refunded", payment("ref-1").state, "the late answer does not overwrite the refund"
    end

    test "temporary provider failures are retried until the capture succeeds" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new(capture: [ :timeout, :timeout, :ok ])

      published = record_publications { perform_enqueued_jobs { Api.request_capture(reference: "ref-1") } }

      assert_equal 3, gateway.calls[:capture]
      assert_equal [ "payments.payment_captured" ], published.map(&:event_type)
    end

    test "a refused capture is reported as a failed capture" do
      authorize
      Gateway.adapter = ScriptedGateway.new(capture: [ :refuse ])

      published = record_publications { perform_enqueued_jobs { Api.request_capture(reference: "ref-1") } }

      assert_equal [ "payments.capture_failed" ], published.map(&:event_type)
      assert_equal "capture_failed", payment("ref-1").state
    end

    test "a provider that never answers leaves the capture pending, retrying, and then in the failed jobs" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new(capture: [ :timeout ] * 10)
      Api.request_capture(reference: "ref-1")

      failures = nil
      published = record_publications { failures = work_off_queue }

      assert_equal 10, gateway.calls[:capture]
      assert_equal [ "Payments::CaptureJob" ], failures.map(&:job_class)
      assert_empty published, "no outcome is reported: nobody knows whether the capture was taken"
      payment = payment("ref-1")
      assert_equal [ "authorized", "capture" ], [ payment.state, payment.pending_operation ]
      assert payment.operation_sent_at

      replay(failures) # the provider is back
      work_off_queue

      assert_equal [ "captured", nil ], [ payment("ref-1").state, payment("ref-1").pending_operation ]
    end

    test "release voids an uncaptured authorization" do
      authorize

      published = record_publications { perform_enqueued_jobs { Api.request_release(reference: "ref-1") } }

      assert_equal [ "payments.authorization_voided" ], published.map(&:event_type)
      assert_equal "voided", payment("ref-1").state
    end

    test "a capture asked for after the release does nothing" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new
      perform_enqueued_jobs { Api.request_release(reference: "ref-1") }

      published = record_publications { perform_enqueued_jobs { Api.request_capture(reference: "ref-1") } }

      assert_empty published
      assert_equal 0, gateway.calls[:capture]
      assert_equal "voided", payment("ref-1").state
    end

    test "release refunds captured money and reports it" do
      authorize
      perform_enqueued_jobs { Api.request_capture(reference: "ref-1") }

      published = record_publications { perform_enqueued_jobs { Api.request_release(reference: "ref-1") } }

      assert_equal [ "payments.refund_issued" ], published.map(&:event_type)
      assert_equal "refunded", payment("ref-1").state
    end

    test "a refused refund is reported as a failed refund" do
      authorize
      perform_enqueued_jobs { Api.request_capture(reference: "ref-1") }
      Gateway.adapter = ScriptedGateway.new(refund: [ :refuse ])

      published = record_publications { perform_enqueued_jobs { Api.request_release(reference: "ref-1") } }

      assert_equal [ "payments.refund_failed" ], published.map(&:event_type)
    end

    test "a refused capture's hold is voided by the release, and repeating the capture reports nothing new" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new(capture: [ :refuse ])
      perform_enqueued_jobs { Api.request_capture(reference: "ref-1") }

      voided = record_publications { perform_enqueued_jobs { Api.request_release(reference: "ref-1") } }
      again = record_publications { perform_enqueued_jobs { Api.request_capture(reference: "ref-1") } }

      assert_equal 1, gateway.calls[:void]
      assert_equal [ "payments.authorization_voided" ], voided.map(&:event_type)
      payment = payment("ref-1")
      assert_equal "capture_failed", payment.state
      assert payment.voided_at
      assert_empty again, "the refusal was reported when it was recorded"
    end

    test "release refunds a captured payment and voids an uncaptured one" do
      authorize("captured")
      authorize("uncaptured")
      perform_enqueued_jobs { Api.request_capture(reference: "captured") }

      published = record_publications do
        perform_enqueued_jobs { Api.request_release(reference: "captured"); Api.request_release(reference: "uncaptured") }
      end

      assert_equal "refunded", payment("captured").state
      assert_equal "voided", payment("uncaptured").state
      assert_equal %w[ payments.authorization_voided payments.refund_issued ], published.map(&:event_type).sort
    end

    test "a release asked for while the capture is at the provider waits for its answer, then refunds" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new
      gateway.define_singleton_method(:capture) do |**options|
        Api.request_release(reference: "ref-1") # only the capture's answer says whether to void or refund
        super(**options)
      end
      Api.request_capture(reference: "ref-1")

      published = record_publications { work_off_queue }

      assert_equal [ 1, 0, 1 ], gateway.calls.values_at(:capture, :void, :refund)
      assert_equal "refunded", payment("ref-1").state
      assert_equal %w[ payments.payment_captured payments.refund_issued ], published.map(&:event_type)
    end

    test "a release asked for while the capture is at the provider voids, once the capture is refused" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new(capture: [ :refuse ])
      gateway.define_singleton_method(:capture) do |**options|
        Api.request_release(reference: "ref-1")
        super(**options)
      end
      Api.request_capture(reference: "ref-1")

      published = record_publications { work_off_queue }

      assert_equal [ 1, 1 ], gateway.calls.values_at(:capture, :void)
      assert_equal %w[ payments.capture_failed payments.authorization_voided ], published.map(&:event_type)
    end

    test "a release asked for before the capture was sent calls the capture off and voids" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new
      Api.request_capture(reference: "ref-1") # staged; not yet run

      published = record_publications do
        Api.request_release(reference: "ref-1")
        work_off_queue
      end

      assert_equal [ 0, 1 ], gateway.calls.values_at(:capture, :void)
      assert_equal "voided", payment("ref-1").state
      assert_equal [ "payments.authorization_voided" ], published.map(&:event_type)
    end

    test "a refused capture is reported within the caller's flow" do
      authorize
      Gateway.adapter = ScriptedGateway.new(capture: [ :refuse ])

      EventRail.with_context(message_id: "checkout-flow-1") { Api.request_capture(reference: "ref-1") }
      capture_job_id = enqueued_jobs.sole["job_id"]
      published = record_publications { work_off_queue }

      failure = published.sole
      assert_equal "payments.capture_failed", failure.event_type
      assert_equal "checkout-flow-1", failure.correlation_id
      assert_equal capture_job_id, failure.causation_id
    end

    test "two authorizations racing for one reference end with one payment" do
      # The other call inserts its payment while this one waits for the provider.
      Gateway.adapter = racing = ScriptedGateway.new
      racing.define_singleton_method(:authorize) do |**|
        Payments::Payment.create!(reference: "ref-1", amount_cents: 4990, currency: "EUR", state: "authorized", authorization_code: "auth_winner")
        "auth_loser"
      end

      authorize

      assert_equal "authorized", payment("ref-1").state
      assert_equal [ "auth_winner" ], Payments::Payment.where(reference: "ref-1").pluck(:authorization_code)
    end

    test "a request for a reference with no payment does nothing" do
      Gateway.adapter = gateway = ScriptedGateway.new

      published = record_publications do
        Api.request_release(reference: "never-authorized")
        Api.request_capture(reference: "never-authorized")
        perform_enqueued_jobs
      end

      assert_empty published
      assert_equal 0, gateway.calls.values.sum
      assert_no_enqueued_jobs
    end

    test "a request whose job the queue refuses at the commit is carried out by the relay" do
      authorize
      refusing_enqueue { Api.request_capture(reference: "ref-1") }
      assert_no_enqueued_jobs

      relay_staged_jobs
      work_off_queue

      assert_equal "captured", payment("ref-1").state
    end
  end
end
