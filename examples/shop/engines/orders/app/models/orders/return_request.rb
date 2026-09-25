module Orders
  # A whole delivered order coming back, within 14 days of delivery. Fulfillment is told to
  # expect the parcel; the refund follows when it arrives (Orders::RefundReturnJob).
  class ReturnRequest
    def initialize(order)
      @order = order
    end

    def call
      unless @order.delivered? || @order.awaiting_return?
        raise Api::NotReturnable, "order #{@order.id} has not been delivered"
      end
      raise Api::NotReturnable, "order #{@order.id} was delivered more than 14 days ago" unless @order.within_return_window?

      Flow.continue(@order, step: "return") do
        @order.transition!(from: "delivered", to: "awaiting_return", return_requested_at: Time.current)
        Fulfillment::Api.expect_return(reference: @order.reference)
      end
      @order
    end
  end
end
