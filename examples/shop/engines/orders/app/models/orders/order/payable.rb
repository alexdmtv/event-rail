module Orders
  class Order
    module Payable
      extend ActiveSupport::Concern

      PAYMENT_DEADLINE = 30.minutes

      included do
        scope :unpaid_past_deadline, -> { where(state: "confirmed", paid_at: nil).where(confirmed_at: ...PAYMENT_DEADLINE.ago) }
      end

      class_methods do
        def cancel_unpaid = request_cancellations(unpaid_past_deadline, reason: "not paid in time")
      end

      # Shipping is requested only here, once the order is paid. An order cancelled meanwhile
      # needs nothing: its cancellation's release makes Payments refund the capture.
      def mark_paid
        update_if({ state: "confirmed", paid_at: nil }, paid_at: Time.current)
        return unless confirmed? && paid_at?

        Fulfillment::Api.request_shipment(
          reference: reference,
          recipient: Fulfillment::Api::Recipient.new(name: customer_name, address: shipping_address),
          items: items
        )
      end
    end
  end
end
