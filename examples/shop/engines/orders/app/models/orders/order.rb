module Orders
  class Order < ApplicationRecord
    STATES = %w[ placed paid shipped delivered awaiting_return refunded cancelled needs_attention ].freeze
    ABANDONED_AFTER = 30.minutes
    RETURN_WINDOW = 14.days

    has_many :line_items, dependent: :destroy

    validates :state, inclusion: { in: STATES }

    STATES.each { |state| define_method(:"#{state}?") { self.state == state } }

    scope :recent, -> { order(placed_at: :desc) }
    scope :abandoned, -> { where(state: "placed").where(placed_at: ...ABANDONED_AFTER.ago) }

    # Moves from one of `from` to `to` unless another process already did; true if this
    # call made the move. Every lifecycle step goes through here, which is what makes a
    # redelivered event or a repeated command a no-op.
    def transition!(from:, to:, **attributes)
      moved = self.class.where(id: id, state: Array(from)).update_all(attributes.merge(state: to, updated_at: Time.current))
      reload
      moved == 1
    end

    def delivered_or_later? = state.in?(%w[ delivered awaiting_return refunded ]) || (needs_attention? && delivered_at?)
    def shipped_or_later? = shipped? || delivered_or_later?
    def within_return_window? = delivered_at.present? && delivered_at > RETURN_WINDOW.ago

    def items = line_items.to_h { |line| [ line.sku, line.quantity ] }

    # What every published order event says about the order.
    def event_attributes
      { order_id: id.to_s, customer_id: customer_id, customer_name: customer_name, customer_email: customer_email }
    end

    def total = { amount_cents: total_cents, currency: currency }
  end
end
