module Payments
  # One card payment for one caller reference, from authorization to capture, void or
  # refund. Every transition is a conditional update, so a command delivered twice moves
  # the payment once.
  #
  # A provider call is made under a claim (see Payment::ProviderCall): no other job may call
  # the provider for this payment until the answer is recorded.
  class Payment < ApplicationRecord
    STATES = %w[ authorized captured capture_failed voided refunded refund_failed ].freeze

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

    # Requests are accepted by enqueuing the job that carries them out, for a reference that may
    # have no payment: its authorization was declined, or never reached the provider. The job
    # then does nothing. The outcome arrives as an event.
    def self.capture_later(reference) = CaptureJob.perform_later!(reference)
    def self.void_later(reference) = VoidJob.perform_later!(reference)
    def self.refund_later(reference) = RefundJob.perform_later!(reference)
    def self.release_later(reference) = ReleaseJob.perform_later!(reference)

    # What each provider call needs to find. A refused capture leaves the card's hold open
    # until it is voided, so an uncaptured authorization is voidable whether its capture
    # was never tried or was refused.
    def capturable? = authorized?
    def voidable? = (authorized? || capture_failed?) && voided_at.nil?
    def refundable? = captured?

    # Each command runs under the claim of the one taking it, and reports the payment's state
    # afterwards whether or not this run changed it.
    def capture(claimant:) = ProviderCall.new(self, claimant).capture
    def void(claimant:) = ProviderCall.new(self, claimant).void
    def refund(claimant:) = ProviderCall.new(self, claimant).refund

    # Gives back whatever the payment holds, decided under the claim: a captured payment is
    # refunded, an uncaptured authorization is voided. A caller undoing its payment -- a
    # cancelled order -- need not know whether a capture has already landed; Payments does.
    def release(claimant:) = ProviderCall.new(self, claimant).release

    # Claims the payment for one provider call; true if the claimant holds it.
    def claim(operation, claimant)
      claimed = self.class.where(id: id).where("operation IS NULL OR operation_job_id = ?", claimant)
        .update_all(operation: operation, operation_job_id: claimant, updated_at: Time.current)
      reload
      claimed == 1
    end

    # Gives up a claim the claimant still holds, without an answer.
    def give_up_claim(claimant) = self.class.where(id: id, operation_job_id: claimant).update_all(operation: nil, operation_job_id: nil, updated_at: Time.current)

    # Records the provider's answer, if any, and gives the claim up.
    def settle(**attributes) = update!(**attributes, operation: nil, operation_job_id: nil)
  end
end
