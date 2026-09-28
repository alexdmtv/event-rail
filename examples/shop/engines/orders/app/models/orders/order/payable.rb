module Orders
  class Order
    # Payment, as Orders sees it: the capture is Payments' business, and the order learns it
    # happened. Money moves before goods do, so shipping is requested only once it is paid.
    module Payable
      extend ActiveSupport::Concern

      # A confirmed order not paid by then is cancelled (see DeadlineSweepJob).
      PAYMENT_DEADLINE = 30.minutes

      included do
        scope :unpaid_past_deadline, -> { where(state: "confirmed", paid_at: nil).where(confirmed_at: ...PAYMENT_DEADLINE.ago) }
      end

      # The capture landed. An order cancelled meanwhile needs nothing: its cancellation asked
      # Payments to give back whatever the payment holds, and Payments refunds a capture.
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
