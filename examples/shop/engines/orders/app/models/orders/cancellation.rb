module Orders
  # Cancels an order that has not been dispatched, giving back what its checkout took:
  # the reserved stock, and the payment -- voided if it was never captured, refunded if it
  # was. An order on its way to the customer cannot be cancelled; it can be returned.
  #
  # Three paths lead here: the customer, a refused capture, and the abandoned-order expiry.
  # The state change and its announcement are two separate writes, so the order records
  # when the cancellation was announced. A cancellation that crashed between the two is
  # finished by whichever path runs next; one that finds both done changes nothing.
  class Cancellation
    def initialize(order, reason:)
      @order = order
      @reason = reason
    end

    def call
      return @order if @order.cancelled? && @order.cancellation_announced_at?
      raise Api::NotCancellable, "order #{@order.id} has been dispatched; request a return instead" unless cancellable?

      Flow.continue(@order, step: "cancel") do
        compensate unless @order.cancelled?
        @order.transition!(from: %w[ placed paid ], to: "cancelled", cancelled_at: Time.current, cancel_reason: @reason)
        announce
      end
      @order
    end

    private
      def cancellable? = @order.placed? || @order.paid? || @order.cancelled?

      def compensate
        Catalog::Api.release(reservation_id: @order.reference)
        if @order.paid?
          Payments::Api.refund(reference: @order.reference)
        else
          # A capture may be in flight. If it lands after this void, Orders refunds it when
          # PaymentCaptured arrives for a cancelled order.
          Payments::Api.void(reference: @order.reference)
        end
      end

      def announce
        EventRail.publish(Events::OrderCancelled.new(**@order.event_attributes, reason: @order.cancel_reason))
        @order.update_columns(cancellation_announced_at: Time.current)
      end
  end
end
