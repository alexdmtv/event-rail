module Payments
  # What capture, void, release and refund share. Each makes at most one provider call, when
  # the payment is in the state the call needs, under the payment's claim (see Payment), and
  # then reports the payment's resulting state as an event -- whether or not this run made
  # the change. Reporting unconditionally is what makes the command safe to repeat: if a
  # previous run crashed after moving the payment but before publishing, this run publishes,
  # under the same identity.
  class PaymentJob < ApplicationJob
    # Another job is calling the provider for this payment; wait for its answer.
    class Busy < StandardError
      include Platform::Aborted
    end

    # A provider that keeps timing out is, eventually, a refusal: the caller learns about it
    # through the failure event rather than waiting forever.
    ATTEMPTS = 5

    queue_as :payments

    retry_on Gateway::TemporaryFailure, wait: 2.seconds, attempts: ATTEMPTS

    # A reference with no payment has nothing to capture, void, release or refund: its
    # authorization was declined, or never reached the provider.
    def perform(reference)
      payment = Payment.find_by(reference: reference) or return

      if operation_for(payment)
        raise Busy, "payment #{reference} is busy with another #{payment.operation}" unless payment.claim!(self.class.name, job_id)

        # Decided again under the claim: another job may have moved the payment meanwhile.
        if (operation = operation_for(payment))
          call_provider(operation, payment)
        else
          payment.settle!
        end
      end
      report(payment)
    end

    private
      def gateway = Gateway.current

      def publish(event) = EventRail.publish(event)

      # The last permitted attempt's temporary failure is decided here, inside perform, so
      # that the outcome is published within this job's EventRail context -- its flow --
      # rather than from a retry_on block, which runs after that context has closed.
      def call_provider(operation, payment)
        send(operation, payment)
      rescue Gateway::Refused => refusal
        refused(operation, payment, refusal.message)
      rescue Gateway::TemporaryFailure => failure
        raise if executions < ATTEMPTS

        refused(operation, payment, "payment provider unavailable: #{failure.message}")
      end

      def capture(payment)
        gateway.capture(idempotency_key: "capture-#{payment.reference}", authorization_code: payment.authorization_code, amount_cents: payment.amount_cents)
        payment.settle!(state: "captured", captured_at: Time.current)
      end

      # A refused capture keeps its state when its hold is voided, so that repeating the
      # capture command still reports the refusal.
      def void(payment)
        gateway.void(idempotency_key: "void-#{payment.reference}", authorization_code: payment.authorization_code)
        payment.settle!(state: payment.authorized? ? "voided" : payment.state, voided_at: Time.current)
      end

      def refund(payment)
        gateway.refund(idempotency_key: "refund-#{payment.reference}", authorization_code: payment.authorization_code, amount_cents: payment.amount_cents)
        payment.settle!(state: "refunded", refunded_at: Time.current)
      end

      def refused(operation, payment, reason)
        case operation
        when :capture then payment.settle!(state: "capture_failed", failure_reason: reason)
        when :refund then payment.settle!(state: "refund_failed", failure_reason: reason)
        when :void
          # An authorization nobody can void expires at the card issuer on its own after
          # days; there is nothing further to report.
          Rails.logger.warn("Could not void payment #{payment.reference}: #{reason}")
          payment.settle!
        end
      end

      def report_capture(payment)
        if payment.captured? || payment.refunded? || payment.refund_failed?
          publish Events::PaymentCaptured.new(reference: payment.reference, amount_cents: payment.amount_cents, currency: payment.currency)
        elsif payment.capture_failed?
          publish Events::CaptureFailed.new(reference: payment.reference, reason: payment.failure_reason)
        end
      end

      def report_void(payment)
        publish Events::AuthorizationVoided.new(reference: payment.reference) if payment.voided_at?
      end

      def report_refund(payment)
        if payment.refunded?
          publish Events::RefundIssued.new(reference: payment.reference, amount_cents: payment.amount_cents, currency: payment.currency)
        elsif payment.refund_failed?
          publish Events::RefundFailed.new(reference: payment.reference, reason: payment.failure_reason)
        end
      end
  end
end
