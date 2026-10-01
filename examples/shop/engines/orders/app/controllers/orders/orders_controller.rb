module Orders
  class OrdersController < ApplicationController
    def show
      render_order Order.find(params[:id])
    end
  end
end
