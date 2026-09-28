class OrdersController < ApplicationController
  def index
    @orders = Orders::Api.recent(limit: 50)
    references = @orders.map(&:reference)
    @payments = Payments::Api.payments(references)
    @shipments = Fulfillment::Api.shipments(references)
    @points = Loyalty::Api.points_for_orders(@orders.map(&:id))
  end

  def show
    @order = Orders::Api.order(params[:id]) or raise ActiveRecord::RecordNotFound
    @flow = Observability::Api.flow(@order.correlation_id)
    @payment = Payments::Api.payment(@order.reference)
    @shipment = Fulfillment::Api.shipment(@order.reference)
    @notifications = Notifications::Api.for_order(@order.id)
    @points = Loyalty::Api.points_for_orders([ @order.id ]).fetch(@order.id.to_s, 0)
  end

  def cancellation
    Orders::Api.request_cancellation(params[:id])
    redirect_to order_path(params[:id]), notice: "Cancellation requested."
  rescue Orders::NotCancellable => refusal
    redirect_to order_path(params[:id]), alert: refusal.message
  end

  def return
    Orders::Api.request_return(params[:id])
    redirect_to order_path(params[:id]), notice: "Return requested. The carrier will bring the parcel back."
  rescue Orders::NotReturnable => refusal
    redirect_to order_path(params[:id]), alert: refusal.message
  end
end
