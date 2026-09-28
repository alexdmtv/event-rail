class CartsController < ApplicationController
  def new
    @customers = Simulation::Api.customers
    @products = Catalog::Api.products
  end

  def create
    cart = Orders::Api.open_cart(
      customer: Simulation::Api.customer_snapshot(params.require(:customer_id)),
      items: params.fetch(:items, {}).permit!.to_h # as submitted: the cart refuses what is not a quantity
    )
    redirect_to cart_path(cart.id)
  rescue Orders::Error => refusal
    redirect_to new_cart_path, alert: "Cart refused: #{refusal.message}"
  end

  def show
    @cart = Orders::Api.cart(params[:id])
    @products = Catalog::Api.products.index_by(&:sku)
  end

  # Placing the cart. Placing it again -- a double click, a retry after a timeout -- returns the
  # same order. It answers once the order is placed; its page shows it confirmed or cancelled
  # a moment later.
  def order
    order = Orders::Api.place_order(params[:id])
    respond_to do |format|
      format.html { redirect_to order_path(order.id), notice: "Order ##{order.id} placed." }
      format.json { render json: { order_id: order.id, status: order.status, url: order_path(order.id) } }
    end
  rescue Orders::Error => refusal
    respond_to do |format|
      format.html { redirect_to cart_path(params[:id]), alert: "Order refused: #{refusal.message}" }
      format.json { render json: { error: refusal.message }, status: :unprocessable_content }
    end
  end
end
