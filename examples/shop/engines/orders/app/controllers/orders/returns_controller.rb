module Orders
  class ReturnsController < ApplicationController
    def create
      render_order Order.find(params[:order_id]).tap(&:request_return), status: :accepted
    end
  end
end
