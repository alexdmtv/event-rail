module Orders
  class Order
    module Payable
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
