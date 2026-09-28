module Orders
  # A customer's commitment: the items and prices of its cart, frozen when it was placed, and
  # what has happened to it since. Its lifecycle is three states -- placed, then confirmed once
  # its stock is held and its card authorized, or cancelled from either. Everything after
  # confirming is recorded as facts, each with its time: paid, shipped, delivered, a
  # cancellation requested or refused. Payment and shipping have states of their own, in
  # Payments and Fulfillment; the order keeps only the facts it acts on.
  #
  # The order and its line items are one aggregate. A return is an aggregate of its own,
  # created through the order (Returnable).
  class Order < ApplicationRecord
    include Confirmable, Payable, Shippable, Cancellable, Returnable

    STATES = %w[ placed confirmed cancelled ].freeze
    RETURN_WINDOW = 14.days

    belongs_to :cart
    has_many :line_items, dependent: :destroy

    # What Orders gives Catalog, Payments and Fulfillment, generated when the order is placed.
    has_secure_token :reference
    attr_readonly :reference, :cart_id

    validates :state, inclusion: { in: STATES }

    STATES.each { |state| define_method(:"#{state}?") { self.state == state } }

    scope :recent, -> { order(created_at: :desc, id: :desc) }

    # The order a reference names, or nil. Payments and Fulfillment serve any caller and know
    # nothing of orders, so a fact they report may be about another caller's reference: not
    # Orders' business.
    def self.for_reference(reference) = find_by(reference: reference)

    # Cancels every order past a deadline: placed and not confirmed in time (Confirmable), or
    # confirmed and not paid in time (Payable). Run every minute by DeadlineSweepJob; returns
    # how many cancellations it requested.
    def self.cancel_overdue
      [ [ unconfirmed_past_deadline, "not confirmed in time" ], [ unpaid_past_deadline, "not paid in time" ] ].sum do |overdue, reason|
        overdue.find_each.count do |order|
          order.request_cancellation(reason: reason)
        rescue NotCancellable
          false # it shipped while the sweep ran
        end
      end
    end

    # The rules that span the order's traits, each stated once. Every verb that could break one
    # checks it under the order's lock. The steps and verbs that span them live here too.
    def cancellable? = (placed? || confirmed?) && shipped_at.nil? && cancellation_requested_at.nil?
    def returnable? = delivered_at.present? && delivered_at > RETURN_WINDOW.ago && !cancelled? && returns.none?

    # The status shown to people, derived from the state and the facts (see Api::Order#status).
    def status
      current_return = returns.first
      if attention_reason? || current_return&.refund_failed? then "needs_attention"
      elsif cancelled? then "cancelled"
      elsif current_return then current_return.refunded? ? "refunded" : "returning"
      elsif delivered_at? then "delivered"
      elsif shipped_at? then "shipped"
      elsif paid_at? then "paid"
      else state
      end
    end

    def total = Money.new(cents: total_cents, currency: currency)
    def items = line_items.to_h { |line| [ line.sku, line.quantity ] }

    # What every published order event says about the order.
    def event_attributes
      { order_id: id.to_s, customer_id: customer_id, customer_name: customer_name, customer_email: customer_email }
    end

    def event_total = { amount_cents: total_cents, currency: currency }

    # The card issuer refused a refund: the return's, or -- for a cancelled order whose capture
    # had landed -- the cancellation's. Either way the order needs a person.
    def flag_refused_refund(reason)
      if (current = returns.first)
        current.record_refund_failure(reason)
      else
        update_if({ attention_reason: nil }, attention_reason: "refund refused: #{reason}")
      end
    end

    private
      # Gives back the stock and the payment the order holds, for a cancellation and for a
      # confirmation that finds the order cancelled under it. Both are safe to repeat, and to
      # send for an order whose stock or payment was never held.
      def release_holds
        Catalog::Api.release(reservation_id: reference)
        Payments::Api.request_release(reference: reference)
      end
  end
end
