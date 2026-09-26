module Orders
  # Cancels an order that has not been dispatched, giving back what its checkout took: the
  # reserved stock, and the payment. An order on its way to the customer cannot be cancelled;
  # it can be returned.
  #
  # Like checkout, it decides within the call and hands the rest to one job:
  #
  #   1. Fulfillment is asked to cancel the shipment. Only Fulfillment knows whether the
  #      parcel has left -- Orders may not have heard yet -- so its refusal is the refusal.
  #   2. The order becomes cancelled.
  #   3. Orders::CancellationJob releases the stock, asks Payments to give back whatever the
  #      payment holds, and announces the cancellation. It is enqueued under an ID derived
  #      from the order, so a repeated announcement carries the same event identity.
  #
  # Three paths lead here: the customer, a refused capture, and the abandoned-order expiry.
  # A cancellation interrupted before its job was enqueued is finished by whichever path
  # runs next; one already announced changes nothing.
  class Cancellation
    def initialize(order, reason:)
      @order = order
      @reason = reason
    end

    def call
      return @order if @order.cancelled? && @order.cancellation_announced_at?

      unless @order.cancelled?
        raise not_cancellable unless @order.placed? || @order.paid?

        stop_shipment
        @order.transition!(from: %w[ placed paid ], to: "cancelled", cancelled_at: Time.current, cancel_reason: @reason)
        raise not_cancellable unless @order.cancelled?
      end

      Flow.continue(@order, step: "cancel") do
        CancellationJob.perform_later_as("orders-cancel-#{@order.id}", @order.id)
      end
      @order
    end

    private
      def stop_shipment
        Fulfillment::Api.cancel_shipment(reference: @order.reference)
      rescue Fulfillment::Api::AlreadyDispatched
        raise not_cancellable
      end

      def not_cancellable = Api::NotCancellable.new("order #{@order.id} has been dispatched; request a return instead")
  end
end
