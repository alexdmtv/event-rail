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

  def new
    @customers = Simulation::Api.customers
    @products = Catalog::Api.products
    @checkout_key = SecureRandom.uuid
  end

  # Checkout, from a form that carries its checkout key. Submitting the same form again --
  # a double click, a retry after a timeout -- returns the same order.
  def create
    order = Orders::Api.checkout(
      customer: Simulation::Api.customer_snapshot(params.require(:customer_id)),
      items: params.fetch(:items, {}).permit!.to_h.transform_values(&:to_i),
      key: params.require(:checkout_key)
    )
    respond_to do |format|
      format.html { redirect_to order_path(order.id), notice: "Order ##{order.id} placed." }
      format.json { render json: { order_id: order.id, url: order_path(order.id) } }
    end
  rescue Orders::Api::Error => rejection
    respond_to do |format|
      format.html { redirect_to new_order_path, alert: "Checkout rejected: #{rejection.message}" }
      format.json { render json: { error: rejection.message }, status: :unprocessable_content }
    end
  end

  def cancel
    Orders::Api.cancel(params[:id])
    redirect_to order_path(params[:id]), notice: "Order cancelled."
  rescue Orders::Api::NotCancellable => refusal
    redirect_to order_path(params[:id]), alert: refusal.message
  end

  def return
    Orders::Api.request_return(params[:id])
    redirect_to order_path(params[:id]), notice: "Return requested. The carrier will bring the parcel back."
  rescue Orders::Api::NotReturnable => refusal
    redirect_to order_path(params[:id]), alert: refusal.message
  end
end
