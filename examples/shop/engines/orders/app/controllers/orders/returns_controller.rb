module Orders
  # A return is a request: the carrier brings the parcel back, and the order is refunded once
  # it arrives.
  class ReturnsController < ApplicationController
    def create
      render_order Order.find(params[:order_id]).tap(&:request_return), status: :accepted
    end
  end
end
