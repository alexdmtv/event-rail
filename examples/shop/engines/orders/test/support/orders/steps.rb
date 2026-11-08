module Orders
  # For Orders' own tests, which work with its records and run only Orders' jobs. What other
  # modules do reaches Orders as their events, which a step publishes and Orders' subscriber hears;
  # their state is set and read through their test support.
  module Steps
    CUSTOMER = TestSupport::CUSTOMER

    def checkout(**) = Order.find(TestSupport.checkout(**).id)
    def place(**) = Order.find(TestSupport.place_and_confirm(**).id)

    def available(sku) = Catalog::TestSupport.available(sku)
    def on_hand(sku) = Catalog::TestSupport.on_hand(sku)

    # Payments captured the order's money, or refused to.
    def pay(order) = hear(Payments::Events::PaymentCaptured.new(reference: order.reference, amount_cents: order.total_cents, currency: "EUR"), by: MarkPaidJob)
    def refuse_capture(order, reason: "card refused") = hear(Payments::Events::CaptureFailed.new(reference: order.reference, reason:), by: CancelRefusedPaymentJob)

    # Payments gave the money back, or couldn't.
    def refund(order) = hear(Payments::Events::RefundIssued.new(reference: order.reference, amount_cents: order.total_cents, currency: "EUR"), by: CompleteRefundJob)
    def refuse_refund(order, reason: "refund refused") = hear(Payments::Events::RefundFailed.new(reference: order.reference, reason:), by: [ RecordCancellationRefundFailureJob, RecordReturnRefundFailureJob ])

    # The carrier picked the parcel up, delivered it, or brought it back.
    def ship(order) = hear(Fulfillment::Events::ShipmentDispatched.new(reference: order.reference, tracking_code: "TRK-1"), by: MarkShippedJob)
    def deliver(order) = hear(Fulfillment::Events::ShipmentDelivered.new(reference: order.reference), by: MarkDeliveredJob)
    def bring_back(order) = hear(Fulfillment::Events::ReturnReceived.new(reference: order.reference), by: ReceiveReturnJob)

    # Publishes the event and runs only Orders' subscribers to it, as delivery would.
    def hear(event, by:) = perform_enqueued_jobs(only: by) { EventRail.publish(event) }
  end
end
