module Orders
  # The payment is captured: the order is paid, and only now is it shipped. Money moves
  # before goods do. A capture landing for an order cancelled meanwhile needs nothing here:
  # the cancellation asked Payments to give back whatever the payment holds, and Payments
  # refunds a capture.
  class MarkPaidJob < ApplicationJob
    subscribes_to Payments::Events::PaymentCaptured

    def perform(event)
      order = Order.find_by(reference: event.reference) or return

      order.transition!(from: "placed", to: "paid", paid_at: Time.current)
      return unless order.paid?

      Fulfillment::Api.request_shipment(
        reference: order.reference,
        recipient: Fulfillment::Api::Recipient.new(name: order.customer_name, address: order.shipping_address),
        items: order.items
      )
    end
  end
end
