module Orders
  # Placing a cart. Placing it again -- a double click, a retry after a timeout -- returns the
  # same order. It answers once the order is placed; confirming it follows, and reading the
  # order shows it confirmed or cancelled a moment later.
  class PlacementsController < ApplicationController
    def create
      render_order Cart.find(params[:cart_id]).place_order, status: :created
    end
  end
end
