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
      assert_equal "captured", Api.payment("ref-1").state
    end

    test "a repeated capture command captures once and reports again under the same identity" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new

      first = record_publications { Api.request_capture(reference: "ref-1"); perform_enqueued_jobs }
      second = record_publications { Api.request_capture(reference: "ref-1"); perform_enqueued_jobs }

      assert_equal 1, gateway.calls[:capture]
      assert_equal first.map(&:event_id), second.map(&:event_id)
    end

    test "captures enqueued by separate callers under random job IDs report one PaymentCaptured" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new

      published = record_publications do
        2.times { CaptureJob.perform_later("ref-1") }
        perform_enqueued_jobs
      end

      assert_equal 1, gateway.calls[:capture]
      assert_equal [ "payments.payment_captured" ] * 2, published.map(&:event_type), "each run reports the capture"
      assert_equal 1, published.map(&:event_id).uniq.size, "the fact has one ID whichever job reports it"
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
      assert_equal "capture_failed", Api.payment("ref-1").state
    end

    test "a provider that never answers leaves the capture retrying, and then in the failed jobs" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new(capture: [ :timeout ] * 10)
      Api.request_capture(reference: "ref-1")

      failures = nil
      published = record_publications { failures = work_off_queue }

      assert_equal 10, gateway.calls[:capture]
      assert_equal [ "Payments::CaptureJob" ], failures.map(&:job_class)
      assert_empty published, "no outcome is reported: the capture has not happened, nor been refused"
      assert_equal "authorized", Api.payment("ref-1").state
    end

    test "void releases an uncaptured authorization" do
      authorize

      published = record_publications { perform_enqueued_jobs { Api.request_void(reference: "ref-1") } }

      assert_equal [ "payments.authorization_voided" ], published.map(&:event_type)
      assert_equal "voided", Api.payment("ref-1").state
    end

    test "void leaves a captured payment alone" do
      authorize
      perform_enqueued_jobs { Api.request_capture(reference: "ref-1") }

      published = record_publications { perform_enqueued_jobs { Api.request_void(reference: "ref-1") } }

      assert_empty published
      assert_equal "captured", Api.payment("ref-1").state
    end

    test "a refund returns captured money and reports it" do
      authorize
      perform_enqueued_jobs { Api.request_capture(reference: "ref-1") }

      published = record_publications { perform_enqueued_jobs { Api.request_refund(reference: "ref-1") } }

      assert_equal [ "payments.refund_issued" ], published.map(&:event_type)
      assert_equal "refunded", Api.payment("ref-1").state
    end

    test "a refused refund is reported as a failed refund" do
      authorize
      perform_enqueued_jobs { Api.request_capture(reference: "ref-1") }
      Gateway.adapter = ScriptedGateway.new(refund: [ :refuse ])

      published = record_publications { perform_enqueued_jobs { Api.request_refund(reference: "ref-1") } }

      assert_equal [ "payments.refund_failed" ], published.map(&:event_type)
    end

    test "a refused capture's hold is voided at the provider, and the refusal still reported" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new(capture: [ :refuse ])
      perform_enqueued_jobs { Api.request_capture(reference: "ref-1") }

      voided = record_publications { perform_enqueued_jobs { Api.request_void(reference: "ref-1") } }
      again = record_publications { perform_enqueued_jobs { Api.request_capture(reference: "ref-1") } }

      assert_equal 1, gateway.calls[:void]
      assert_equal [ "payments.authorization_voided" ], voided.map(&:event_type)
      payment = Api.payment("ref-1")
      assert_equal "capture_failed", payment.state
      assert payment.voided_at
      assert_equal [ "payments.capture_failed" ], again.map(&:event_type)
    end

    test "release refunds a captured payment and voids an uncaptured one" do
      authorize("captured")
      authorize("uncaptured")
      perform_enqueued_jobs { Api.request_capture(reference: "captured") }

      published = record_publications do
        perform_enqueued_jobs { Api.request_release(reference: "captured"); Api.request_release(reference: "uncaptured") }
      end

      assert_equal "refunded", Api.payment("captured").state
      assert_equal "voided", Api.payment("uncaptured").state
      assert_equal %w[ payments.authorization_voided payments.refund_issued ], published.map(&:event_type).sort
    end

    test "a void arriving while a capture is at the provider waits, and the capture stands" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new
      gateway.define_singleton_method(:capture) do |**options|
        VoidJob.perform_now("ref-1") # the void finds the payment claimed and retries later
        super(**options)
      end

      published = record_publications do
        CaptureJob.perform_now("ref-1")
        work_off_queue
      end

      assert_equal [ 1, 0 ], [ gateway.calls[:capture], gateway.calls[:void] ]
      assert_equal "captured", Api.payment("ref-1").state
      assert_equal [ "payments.payment_captured" ], published.map(&:event_type)
    end

    test "a capture arriving while a void is at the provider waits, and the void stands" do
      authorize
      Gateway.adapter = gateway = ScriptedGateway.new
      gateway.define_singleton_method(:void) do |**options|
        CaptureJob.perform_now("ref-1")
        super(**options)
      end

      published = record_publications do
        VoidJob.perform_now("ref-1")
        work_off_queue
      end

      assert_equal [ 0, 1 ], [ gateway.calls[:capture], gateway.calls[:void] ]
      assert_equal "voided", Api.payment("ref-1").state
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

      payment = authorize

      assert_equal "authorized", payment.state
      assert_equal [ "auth_winner" ], Payments::Payment.where(reference: "ref-1").pluck(:authorization_code)
    end

    test "a command for a reference with no payment does nothing" do
      Gateway.adapter = gateway = ScriptedGateway.new

      published = record_publications do
        Api.request_void(reference: "never-authorized")
        Api.request_release(reference: "never-authorized")
        Api.request_capture(reference: "never-authorized")
        perform_enqueued_jobs
      end

      assert_empty published
      assert_equal 0, gateway.calls.values.sum
      assert_no_enqueued_jobs # no retry of a command that found nothing
    end

    test "a command the queue refuses raises rather than returning" do
      authorize

      assert_raises(ActiveJob::EnqueueError) { refusing_enqueue { Api.request_void(reference: "ref-1") } }
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
