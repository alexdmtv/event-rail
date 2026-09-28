module Payments
  class Payment
    # One command on a payment: at most one provider call, when the payment is in the state
    # the call needs, under the payment's claim, and then a report of the payment's resulting
    # state as an event -- whether or not this run made the change. Reporting unconditionally
    # is what makes a command safe to repeat: if a previous run crashed after moving the
    # payment but before publishing, this run publishes, under the same identity.
    #
    # The claimant is the job carrying the command. Its ID survives the job's retries, so a
    # retry keeps the claim it took; it is an identity, not a count of attempts.
    class ProviderCall
      # Another command is calling the provider for this payment; wait for its answer.
      class Busy < StandardError
        include Platform::Aborted
      end

      def initialize(payment, claimant)
        @payment = payment
        @claimant = claimant
      end

      def capture = perform(-> { :capture if @payment.capturable? }) { report_capture }
      def void = perform(-> { :void if @payment.voidable? }) { report_void }
      def refund = perform(-> { :refund if @payment.refundable? }) { report_refund }

      def release
        decision = -> { @payment.refundable? ? :refund : (:void if @payment.voidable?) }
        perform(decision) { @payment.refunded? || @payment.refund_failed? ? report_refund : report_void }
      end

      private
        def perform(decision)
          if decision.call
            raise Busy, "payment #{@payment.reference} is busy with another #{@payment.operation}" unless @payment.claim(decision.call, @claimant)

            # Decided again under the claim: another command may have moved the payment meanwhile.
            (operation = decision.call) ? call_provider(operation) : @payment.settle
          end
          yield
        end

        def gateway = Gateway.current

        # A temporary failure is raised, for the job to retry; a refusal is the answer.
        def call_provider(operation)
          __send__(:"#{operation}_now")
        rescue Gateway::Refused => refusal
          refused(operation, refusal.message)
        end

        def capture_now
          gateway.capture(idempotency_key: "capture-#{@payment.reference}", authorization_code: @payment.authorization_code, amount_cents: @payment.amount_cents)
          @payment.settle(state: "captured", captured_at: Time.current)
        end

        # A refused capture keeps its state when its hold is voided, so that repeating the
        # capture command still reports the refusal.
        def void_now
          gateway.void(idempotency_key: "void-#{@payment.reference}", authorization_code: @payment.authorization_code)
          @payment.settle(state: @payment.authorized? ? "voided" : @payment.state, voided_at: Time.current)
        end

        def refund_now
          gateway.refund(idempotency_key: "refund-#{@payment.reference}", authorization_code: @payment.authorization_code, amount_cents: @payment.amount_cents)
          @payment.settle(state: "refunded", refunded_at: Time.current)
        end

        def refused(operation, reason)
          case operation
          when :capture then @payment.settle(state: "capture_failed", failure_reason: reason)
          when :refund then @payment.settle(state: "refund_failed", failure_reason: reason)
          when :void
            # An authorization nobody can void expires at the card issuer on its own after
            # days; there is nothing further to report.
            Rails.error.report(Gateway::Refused.new("could not void payment #{@payment.reference}: #{reason}"), handled: true, severity: :warning)
            @payment.settle
          end
        end

        def publish(event) = EventRail.publish(event)

        def report_capture
          if @payment.captured? || @payment.refunded? || @payment.refund_failed?
            publish Events::PaymentCaptured.new(reference: @payment.reference, amount_cents: @payment.amount_cents, currency: @payment.currency)
          elsif @payment.capture_failed?
            publish Events::CaptureFailed.new(reference: @payment.reference, reason: @payment.failure_reason)
          end
        end

        def report_void
          publish Events::AuthorizationVoided.new(reference: @payment.reference) if @payment.voided_at?
        end

        def report_refund
          if @payment.refunded?
            publish Events::RefundIssued.new(reference: @payment.reference, amount_cents: @payment.amount_cents, currency: @payment.currency)
          elsif @payment.refund_failed?
            publish Events::RefundFailed.new(reference: @payment.reference, reason: @payment.failure_reason)
          end
        end
    end
  end
end
