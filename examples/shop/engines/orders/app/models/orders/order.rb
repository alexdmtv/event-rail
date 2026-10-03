module Orders
  # Three states: placed, then confirmed or cancelled. Everything after confirming is a fact with
  # its time (paid_at, shipped_at, ...); Payments and Fulfillment keep their own states, and the
  # order keeps only the facts it acts on.
  class Order < ApplicationRecord
    include Confirmable, Payable, Shippable, Expirable, Cancellable, Returnable

    CURRENCY = "EUR"
    RETURN_WINDOW = 14.days

    belongs_to :cart
    has_many :line_items, dependent: :destroy

    # The key Catalog, Payments and Fulfillment know the order by, so it must never change.
    has_secure_token :reference
    attr_readonly :reference, :cart_id

    # Its bang methods (cancelled!) skip the order's transitions; never call them.
    enum :state, %w[ placed confirmed cancelled ].index_by(&:itself), validate: true

    # The announcement and the confirmation are staged in the order's transaction, so they
    # commit or roll back with it.
    def self.place(cart:, quote:)
      transaction do
        create!(
          cart:, state: "placed", **cart.slice(:customer_id, :customer_name, :customer_email, :shipping_address),
          total_cents: quote.total_cents, currency: CURRENCY,
          line_items: quote.lines.map do |line|
            LineItem.new(sku: line.sku, name: line.name, quantity: line.quantity, unit_price_cents: line.unit_price_cents)
          end
        ).tap do |order|
          EventRail.stage(order.announcements.placed)
          ConfirmJob.stage(order)
        end
      end
    end

    # nil for a reference that is not an order's: Payments and Fulfillment serve other callers too.
    def self.for_reference(reference) = find_by(reference: reference)

    # Rules that span the traits. A verb that depends on one checks it under the order's lock.
    def cancellable? = (placed? || confirmed?) && shipped_at.nil? && cancellation_requested_at.nil?
    def returnable? = delivered_at.present? && delivered_at > RETURN_WINDOW.ago && !cancelled? && self.return.nil?

    def status
      current_return = self.return
      if attention_reason? || current_return&.refund_failed? then "needs_attention"
      elsif cancelled? then "cancelled"
      elsif current_return then current_return.refunded? ? "refunded" : "returning"
      elsif delivered_at? then "delivered"
      elsif shipped_at? then "shipped"
      elsif paid_at? then "paid"
      else state
      end
    end

    def announcements = Announcements.new(self)

    # With no return, the refused refund is a cancelled order's, for a capture that had landed.
    def flag_refused_refund(reason)
      if self.return
        self.return.record_refund_failure(reason)
      else
        update_if({ attention_reason: nil }, attention_reason: "refund refused: #{reason}")
      end
    end

    private
      # Catalog and Fulfillment take an order's goods as quantities by SKU.
      def quantities_by_sku = line_items.to_h { |line| [ line.sku, line.quantity ] }

      # Safe to repeat, and to call for an order whose stock or payment was never held.
      def release_holds
        Catalog::Api.release(reservation_id: reference)
        Payments::Api.request_release(reference: reference)
      end
  end
end
