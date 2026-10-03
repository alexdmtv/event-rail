module Orders
  class Order
    module Payable
      # Only a confirmed order is paid for. Safe to repeat: Payments takes the money once per
      # reference. Answered by PaymentCaptured (mark_paid) or CaptureFailed (request_cancellation).
      def request_payment
        Payments::Api.request_capture(reference: reference) if confirmed?
      end

      # An order cancelled meanwhile needs nothing: its cancellation's release makes Payments
      # refund the capture.
      def mark_paid
        update_if({ state: "confirmed", paid_at: nil }, paid_at: Time.current)
        request_shipment
      end
    end
  end
end
