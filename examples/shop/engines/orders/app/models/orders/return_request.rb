module Orders
  # A whole delivered order coming back, within 14 days of delivery. In one transaction the
  # order becomes awaiting return and Orders::RequestReturnJob is staged, which tells
  # Fulfillment to expect the parcel; the refund follows when it arrives
  # (Orders::RefundReturnJob). A request repeated for an order already awaiting its return
  # returns it unchanged: the 14 days apply to the first request.
  class ReturnRequest
    def initialize(order)
      @order = order
    end

    def call
      return @order if @order.awaiting_return?
      raise Api::NotReturnable, "order #{@order.id} has not been delivered" unless @order.delivered?
      raise Api::NotReturnable, "order #{@order.id} was delivered more than 14 days ago" unless @order.within_return_window?

      Flow.continue(@order, step: "return") do
        Order.transaction do
          RequestReturnJob.stage_later(@order.id) if @order.transition!(from: "delivered", to: "awaiting_return", return_requested_at: Time.current)
        end
      end
      @order
    end
  end
end
