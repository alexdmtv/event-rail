module Orders
  # The payment is captured: the order is paid, and only now is it shipped. Money moves
  # before goods do.
  class MarkPaidJob < ApplicationJob
    subscribes_to Payments::Events::PaymentCaptured

    def perform(event)
      order = Order.find_by(reference: event.reference) or return

      order.transition!(from: "placed", to: "paid", paid_at: Time.current)
      if order.paid?
        Fulfillment::Api.request_shipment(
          reference: order.reference,
          recipient: Fulfillment::Api::Recipient.new(name: order.customer_name, address: order.shipping_address),
          items: order.items
        )
      elsif order.cancelled?
        # The customer cancelled while the capture was in flight. The void came too late,
        # so the money goes back as a refund.
        Payments::Api.refund(reference: order.reference)
      end
    end
  end
end
