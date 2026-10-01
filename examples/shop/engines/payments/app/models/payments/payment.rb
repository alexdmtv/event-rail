module Payments
  # One card payment for one caller reference, from authorization to capture, void or
  # refund.
  #
  # Callers ask for two things: the money taken (a capture), and the money given back (a
  # release). Each request is recorded on the payment under its lock, and the payment then
  # makes at most one provider call at a time -- its pending operation -- carried out by a job.
  # A capture and a void of one authorization must never race at the provider. A call is
  # marked sent just before it is made, and one sent whose answer is unknown, a timeout, stays
  # pending until its answer is known: replaying its job asks again under the same idempotency
  # key.
  #
  # A release, once asked for, stays asked for. A capture never starts after it; a pending
  # capture not yet sent is called off; and one already sent is followed by the release once
  # its answer is recorded: a refund if the money was taken, a void if not.
  class Payment < ApplicationRecord
    STATES = %w[ authorized captured capture_failed voided refunded refund_failed ].freeze
    OPERATIONS = { "capture" => CaptureJob, "void" => VoidJob, "refund" => RefundJob }.freeze

    validates :state, inclusion: { in: STATES }

    STATES.each { |state| define_method(:"#{state}?") { self.state == state } }

    # Places a hold of the amount on the customer's card. Repeating it for the same reference
    # returns the existing authorization rather than holding the amount twice, and two calls
    # racing for one reference end with one payment: the provider sees one idempotency key,
    # and the loser of the insert returns the winner's payment.
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

    # A request may name a reference with no payment -- its authorization declined, or never
    # reached the provider -- and then there is nothing to do.
    def self.request_capture(reference) = find_by(reference: reference)&.request_capture
    def self.request_release(reference) = find_by(reference: reference)&.request_release

    # What each provider call needs to find. A refused capture leaves the card's hold open
    # until it is voided, so an uncaptured authorization is voidable whether its capture
    # was never tried or was refused.
    def capturable? = authorized?
    def voidable? = (authorized? || capture_failed?) && voided_at.nil?
    def refundable? = captured?

    def pending?(generation = operation_generation) = pending_operation.present? && operation_generation == generation

    # Asks for the money. A capture already pending is the same request; a release asked for
    # first wins.
    def request_capture
      with_lock { start("capture") if capturable? && !release_requested_at? && pending_operation.nil? }
    end

    # Asks for the money back: refunded if it was taken, voided if not. A call already sent
    # is waited for, since only its answer says which.
    def request_release
      with_lock do
        update!(release_requested_at: Time.current) unless release_requested_at?
        start_release if pending_operation.nil? || (pending_operation == "capture" && operation_sent_at.nil?)
      end
    end

    # Makes the pending call, if it is still the one the job was started for, and records the
    # answer. The call is marked sent under the payment's lock and made outside it; a temporary
    # failure is raised for the job to retry, and the call stays pending.
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

      # Records the answer, with the event reporting it, under the lock -- but only for the
      # call that is still pending: a second delivery of the same job, or one replayed after
      # the answer was recorded, changes nothing. A release asked for while a capture was
      # pending follows it in the same transaction.
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
