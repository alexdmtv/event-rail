module Payments
  # A card payment under a caller's reference, and the calls made to the provider for it. Its
  # state is where the money last stood, as the provider confirmed. Only one call is outstanding at
  # a time, so a capture and a void are never outstanding together; a call whose answer is unknown stays
  # outstanding and is sent again under the same idempotency key, which the provider answers the
  # same way. A release, once asked for, stays asked for, and follows any capture already sent.
  class Payment < ApplicationRecord
    has_many :provider_calls, class_name: "ProviderCall", dependent: :delete_all

    # Its bang methods (captured!) skip the payment's transitions; never call them.
    enum :state, %w[ authorized captured voided refunded ].index_by(&:itself), validate: true

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

    # Once only: a refused capture is not asked again.
    def request_capture
      with_lock { call_provider("capture") if authorized? && !release_requested_at? && provider_calls.outstanding.none? }
    end

    # Refunds if the money was taken, voids if not. A capture not yet sent is called off; one
    # already sent is waited for, since only its answer says which, and its settling releases.
    def request_release
      with_lock do
        update!(release_requested_at: Time.current) unless release_requested_at?

        outstanding = provider_calls.outstanding.first
        if outstanding.nil? then release
        elsif outstanding.capture? && outstanding.pending? then outstanding.supersede && release
        end
      end
    end

    # CallProviderJob's step. Marks the call sent under the lock and makes it outside, so the
    # lock is never held across the network; a temporary failure raises for the job to retry,
    # and the call stays sent. A call answered or superseded meanwhile is left alone.
    def carry_out(call_id)
      call = with_lock { provider_calls.outstanding.find_by(id: call_id)&.tap(&:mark_sent) }
      settle(call, call.send_to_provider) if call
    end

    def announcements = Announcements.new(self)

    private
      def release
        if captured? then call_provider("refund")
        elsif authorized? then call_provider("void")
        end
      end

      def call_provider(kind)
        return if provider_calls.exists?(kind: kind)

        CallProviderJob.stage(provider_calls.create!(kind: kind, state: "pending", idempotency_key: "#{kind}-#{reference}"))
      end

      # Only a call still sent is answered, so a duplicate or replayed job changes nothing. The
      # answer, the money it moved, its announcement and a release waiting for a capture commit
      # together.
      def settle(call, refusal)
        with_lock do
          next unless call.reload.sent?

          call.answer(refusal)
          move_money(call) if call.succeeded?
          report_unvoidable(call) if call.void? && call.refused?
          announcement = announcements.for(call)
          EventRail.stage(announcement) if announcement
          release if call.capture? && release_requested_at?
        end
      end

      def move_money(call)
        case call.kind
        when "capture" then update!(state: "captured", captured_at: Time.current)
        when "void" then update!(state: "voided", voided_at: Time.current)
        when "refund" then update!(state: "refunded", refunded_at: Time.current)
        end
      end

      # An unvoidable authorization expires at the issuer on its own; only report it.
      def report_unvoidable(call)
        Rails.error.report(Gateway::Refused.new("could not void payment #{reference}: #{call.failure_reason}"), handled: true, severity: :warning)
      end
  end
end
