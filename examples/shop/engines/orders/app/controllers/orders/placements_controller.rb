module Orders
  class PlacementsController < ApplicationController
    def create
      render_order Cart.find(params[:cart_id]).place_order, http_status: :created
    end
  end
end
