module Payments
  # One card payment for one caller reference, from authorization to capture, void or
  # refund. Every transition is a conditional update, so a command delivered twice moves
  # the payment once.
  #
  # A provider call is made under a claim: the job making it records the operation and its
  # own job ID first, and no other job may call the provider for this payment until the
  # answer is recorded. So a capture and a void of the same authorization never both reach
  # the provider, and a provider's success is never discarded because another job moved the
  # payment in the meantime. A job's retry keeps its job ID, and so its claim.
  class Payment < ApplicationRecord
    STATES = %w[ authorized captured capture_failed voided refunded refund_failed ].freeze

    validates :state, inclusion: { in: STATES }

    STATES.each { |state| define_method(:"#{state}?") { self.state == state } }

    # What each provider call needs to find. A refused capture leaves the card's hold open
    # until it is voided, so an uncaptured authorization is voidable whether its capture
    # was never tried or was refused.
    def capturable? = authorized?
    def voidable? = (authorized? || capture_failed?) && voided_at.nil?
    def refundable? = captured?

    # Moves from one of `from` to `to` unless another process already did; true if this
    # call made the move.
    def transition!(from:, to:, **attributes)
      moved = self.class.where(id: id, state: Array(from)).update_all(attributes.merge(state: to, updated_at: Time.current))
      reload
      moved == 1
    end

    # Claims the payment for one provider call by the given job; true if that job holds it.
    def claim!(operation, job_id)
      claimed = self.class.where(id: id).where("operation IS NULL OR operation_job_id = ?", job_id)
        .update_all(operation: operation, operation_job_id: job_id, updated_at: Time.current)
      reload
      claimed == 1
    end

    # Records the provider's answer, if any, and gives the claim up.
    def settle!(**attributes)
      update!(**attributes, operation: nil, operation_job_id: nil)
    end
  end
end
