module Orders
  class Order
    module Payable
      # Safe to repeat: Payments takes the money once per reference.
      def request_payment = Payments::Api.request_capture(reference: reference)

      # An order cancelled meanwhile needs nothing: its cancellation's release makes Payments
      # refund the capture.
      def mark_paid
        update_if({ state: "confirmed", paid_at: nil }, paid_at: Time.current)
        request_shipment if confirmed? && paid_at?
      end
    end
  end
end
