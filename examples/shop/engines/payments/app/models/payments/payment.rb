module Payments
  # One card payment for one caller reference, from authorization to capture, void or
  # refund. Every transition is a conditional update, so a command delivered twice moves
  # the payment once.
  class Payment < ApplicationRecord
    STATES = %w[ authorized captured capture_failed voided refunded refund_failed ].freeze

    validates :state, inclusion: { in: STATES }

    STATES.each { |state| define_method(:"#{state}?") { self.state == state } }

    # Moves from one of `from` to `to` unless another process already did; true if this
    # call made the move.
    def transition!(from:, to:, **attributes)
      moved = self.class.where(id: id, state: Array(from)).update_all(attributes.merge(state: to, updated_at: Time.current))
      reload
      moved == 1
    end
  end
end
