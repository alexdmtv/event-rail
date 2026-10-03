module Orders
  # Three states: placed, then confirmed or cancelled. Everything after confirming is a fact with
  # its time (paid_at, shipped_at, ...); Payments and Fulfillment keep their own states, and the
  # order keeps only the facts it acts on.
  class Order < ApplicationRecord
    include Confirmable, Payable, Shippable, Cancellable, Returnable

    STATES = %w[ placed confirmed cancelled ].freeze
    CURRENCY = "EUR"
    RETURN_WINDOW = 14.days

    belongs_to :cart
    has_many :line_items, dependent: :destroy

    # The key Catalog, Payments and Fulfillment know the order by, so it must never change.
    has_secure_token :reference
    attr_readonly :reference, :cart_id

    validates :state, inclusion: { in: STATES }

    STATES.each { |state| define_method(:"#{state}?") { self.state == state } }

    # An order placed from the cart, priced as the quote says, recorded with its line items in one
    # save; its announcement and its confirmation are staged in the same transaction.
    def self.place(cart:, quote:)
      new(
        cart:, state: "placed", customer_id: cart.customer_id, customer_name: cart.customer_name, customer_email: cart.customer_email,
        shipping_address: cart.shipping_address, total_cents: quote.total_cents, currency: CURRENCY,
        line_items: quote.lines.map { |line| LineItem.new(line.to_h) }
      ).tap(&:place)
    end

    # nil for a reference that is not an order's: Payments and Fulfillment serve other callers too.
    def self.for_reference(reference) = find_by(reference: reference)

    # Returns how many cancellations it requested.
    def self.cancel_overdue
      [ [ unconfirmed_past_deadline, "not confirmed in time" ], [ unpaid_past_deadline, "not paid in time" ] ].sum do |overdue, reason|
        overdue.find_each.count do |order|
          order.request_cancellation(reason: reason)
        rescue NotCancellable
          false # it shipped while the sweep ran
        end
      end
    end

    # Rules that span the traits. A verb that depends on one checks it under the order's lock.
    def cancellable? = (placed? || confirmed?) && shipped_at.nil? && cancellation_requested_at.nil?
    def returnable? = delivered_at.present? && delivered_at > RETURN_WINDOW.ago && !cancelled? && returns.none?

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

    def event_attributes
      { order_id: id.to_s, customer_id: customer_id, customer_name: customer_name, customer_email: customer_email }
    end

    def event_total = { amount_cents: total_cents, currency: currency }

    # With no return, the refused refund is a cancelled order's, for a capture that had landed.
    def flag_refused_refund(reason)
      if (current = returns.first)
        current.record_refund_failure(reason)
      else
        update_if({ attention_reason: nil }, attention_reason: "refund refused: #{reason}")
      end
    end

    private
      # Safe to repeat, and to call for an order whose stock or payment was never held.
      def release_holds
        Catalog::Api.release(reservation_id: reference)
        Payments::Api.request_release(reference: reference)
      end
  end
end
