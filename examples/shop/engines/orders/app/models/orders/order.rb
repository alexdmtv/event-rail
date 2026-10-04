module Orders
  # Three states: placed, then confirmed or cancelled. Everything after confirming is a fact with
  # its time (paid_at, shipped_at, ...); Payments and Fulfillment keep their own states, and the
  # order keeps only the facts it acts on.
  class Order < ApplicationRecord
    include Confirmable, Payable, Shippable, Expirable, Cancellable, Returnable

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
          total_cents: quote.total_cents, currency: quote.currency,
          line_items: quote.lines.map do |line|
            LineItem.new(sku: line.sku, name: line.name, quantity: line.quantity, unit_price_cents: line.unit_price_cents)
          end
        ).tap do |order|
          EventRail.stage(order.announcements.placed)
          order.confirm_later
        end
      end
    end

    # nil for a reference that is not an order's: Payments and Fulfillment serve other callers too.
    def self.for_reference(reference) = find_by(reference: reference)

    def status
      current_return = self.return
      if refund_refused_at? || current_return&.refund_failed? then "needs_attention"
      elsif cancelled? then "cancelled"
      elsif current_return then current_return.refunded? ? "refunded" : "returning"
      elsif delivered_at? then "delivered"
      elsif shipped_at? then "shipped"
      elsif paid_at? then "paid"
      else state
      end
    end

    def announcements = Announcements.new(self)

    # Payments refunds an order for one of two reasons: its received return, or its cancellation
    # after the capture had landed.
    def flag_refused_refund(reason)
      if self.return then self.return.record_refund_failure(reason)
      else record_refund_failure(reason)
      end
    end

    private
      # Catalog and Fulfillment take an order's goods as quantities by SKU.
      def quantities_by_sku = line_items.to_h { |line| [ line.sku, line.quantity ] }

      # Safe to repeat, and to call for an order whose stock or payment was never held. Of the
      # release's answers, only RefundFailed concerns a cancelled order (flag_refused_refund).
      def release_holds
        Catalog::Api.release(reservation_id: reference)
        Payments::Api.request_release(reference: reference)
      end
  end
end
