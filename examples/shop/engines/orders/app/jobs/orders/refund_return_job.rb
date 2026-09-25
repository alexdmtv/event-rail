module Orders
  # A returned parcel is back: its items go back on the shelf and the customer's money goes
  # back to their card. The return completes when Payments reports the refund.
  class RefundReturnJob < ApplicationJob
    subscribes_to Fulfillment::Events::ReturnReceived

    def perform(event)
      order = Order.find_by(reference: event.reference) or return
      return unless order.awaiting_return?

      Catalog::Api.restock(reservation_id: order.reference)
      Payments::Api.refund(reference: order.reference)
    end
  end
end
