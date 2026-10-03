module Payments
  # Makes at most one provider call at a time, its pending operation, so a capture and a void
  # never race at the provider. A sent call whose answer is unknown stays pending and is asked
  # again under the same idempotency key; the generation tells a stale job to do nothing. A
  # release, once asked for, stays asked for, and follows any capture already sent.
  class Payment < ApplicationRecord
    STATES = %w[ authorized captured capture_failed voided refunded refund_failed ].freeze
    OPERATIONS = { "capture" => CaptureJob, "void" => VoidJob, "refund" => RefundJob }.freeze

    validates :state, inclusion: { in: STATES }

    STATES.each { |state| define_method(:"#{state}?") { self.state == state } }

    # Safe to repeat: two calls racing for one reference share an idempotency key at the
    # provider, and the loser of the insert returns the winner's payment.
    def self.authorize(reference:, amount_cents:, currency:)
      find_by(reference: reference) || begin
        code = Gateway.current.authorize(idempotency_key: "authorize-#{reference}", amount_cents: amount_cents, currency: currency)
        create_or_find_by!(reference: reference) do |payment|
          payment.assign_attributes(amount_cents: amount_cents, currency: currency, state: "authorized", authorization_code: code)
        end
      end
    rescue Gateway::Refused => refusal
      raise Declined, refusal.message
    rescue Gateway::TemporaryFailure => failure
      raise Unavailable, failure.message
    end

    def self.request_capture(reference) = find_by(reference: reference)&.request_capture
    def self.request_release(reference) = find_by(reference: reference)&.request_release

    # A refused capture leaves the card's hold open, so it is still voidable.
    def capturable? = authorized?
    def voidable? = (authorized? || capture_failed?) && voided_at.nil?
    def refundable? = captured?

    def pending?(generation = operation_generation) = pending_operation.present? && operation_generation == generation

    def request_capture
      with_lock { start("capture") if capturable? && !release_requested_at? && pending_operation.nil? }
    end

    # Refunds if the money was taken, voids if not; a call already sent is waited for, since
    # only its answer says which.
    def request_release
      with_lock do
        update!(release_requested_at: Time.current) unless release_requested_at?
        start_release if pending_operation.nil? || (pending_operation == "capture" && operation_sent_at.nil?)
      end
    end

    # Marks the call sent under the lock and makes it outside; a temporary failure is raised
    # for the job to retry, and the call stays pending.
    def carry_out(generation)
      sending = with_lock do
        update!(operation_sent_at: Time.current) if pending?(generation) && operation_sent_at.nil?
        pending?(generation)
      end
      settle(generation, ProviderCall.new(self).public_send(pending_operation)) if sending
    end

    private
      # A pending call not yet sent is replaced; its job then finds another generation.
      def start(operation)
        update!(pending_operation: operation, operation_sent_at: nil, operation_generation: operation_generation + 1)
        OPERATIONS.fetch(operation).stage(self, operation_generation)
      end

      def start_release
        if refundable? then start("refund")
        elsif voidable? then start("void")
        else update!(pending_operation: nil, operation_sent_at: nil)
        end
      end

      # Only the call still pending is recorded, so a duplicate or replayed job changes nothing.
      # A release asked for during a capture follows it in the same transaction.
      def settle(generation, answer)
        with_lock do
          next unless pending?(generation)

          operation = pending_operation
          update!(**answer, pending_operation: nil, operation_sent_at: nil)
          report(operation)
          start_release if operation == "capture" && release_requested_at?
        end
      end

      def report(operation)
        event =
          case operation
          when "capture"
            if captured? then Events::PaymentCaptured.new(reference:, amount_cents:, currency:)
            elsif capture_failed? then Events::CaptureFailed.new(reference:, reason: failure_reason)
            end
          when "void" then Events::AuthorizationVoided.new(reference:) if voided_at?
          when "refund"
            if refunded? then Events::RefundIssued.new(reference:, amount_cents:, currency:)
            elsif refund_failed? then Events::RefundFailed.new(reference:, reason: failure_reason)
            end
          end
        EventRail.stage(event) if event
      end
  end
end
