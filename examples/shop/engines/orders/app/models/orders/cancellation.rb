module Orders
  # Cancels an order that has not been dispatched, giving back what its checkout took: the
  # reserved stock, and the payment. An order on its way to the customer cannot be cancelled;
  # it can be returned. One still being placed cannot be cancelled until it is placed, and a
  # rejected one has nothing to cancel.
  #
  # Like checkout, it records the decision and stages what follows:
  #
  #   1. Fulfillment is asked to cancel the shipment. Only Fulfillment knows whether the
  #      parcel has left -- Orders may not have heard yet -- so its refusal is the refusal.
  #   2. In one transaction, the order becomes cancelled and Orders::CancellationJob is
  #      staged. The job releases the stock, asks Payments to give back whatever the payment
  #      holds, and announces the cancellation, retrying each step until it is done; a
  #      repeated announcement carries the same event identity, as OrderCancelled is
  #      identified by its order.
  #
  # Only another cancellation can make the order's move fail once Fulfillment has stopped the
  # shipment, and a stopped shipment is what that cancellation wanted too. Fulfillment's call
  # stays outside the transaction: inside it, the two would commit together only while both
  # modules share a database.
  #
  # Three paths lead here: the customer, a refused capture, and the abandoned-order expiry.
  class Cancellation
    def initialize(order, reason:)
      @order = order
      @reason = reason
    end

    def call
      return @order if @order.cancelled?
      raise Api::NotCancellable, "order #{@order.id} is still being placed" if @order.pending?
      raise Api::NotCancellable, "order #{@order.id} was not placed" if @order.rejected?
      raise not_cancellable unless @order.placed? || @order.paid?

      stop_shipment
      Flow.continue(@order, step: "cancel") do
        Order.transaction do
          if @order.transition!(from: %w[ placed paid ], to: "cancelled", cancelled_at: Time.current, cancel_reason: @reason)
            CancellationJob.stage_later(@order.id)
          end
        end
      end
      raise not_cancellable unless @order.cancelled?

      @order
    end

    private
      def stop_shipment
        Fulfillment::Api.cancel_shipment(reference: @order.reference)
      rescue Fulfillment::AlreadyDispatched
        raise not_cancellable
      end

      def not_cancellable = Api::NotCancellable.new("order #{@order.id} has been dispatched; request a return instead")
  end
end
