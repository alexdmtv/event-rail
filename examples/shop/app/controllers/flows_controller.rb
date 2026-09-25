# A publication in the live feed links to the flow it belongs to.
class FlowsController < ApplicationController
  def show
    order = Orders::Api.order_for_correlation(params[:correlation_id])
    order ? redirect_to(order_path(order.id)) : redirect_to(root_path, alert: "That flow belongs to no order.")
  end
end
