module Orders
  # A cancellation is a request: it is recorded at once and carried out, or refused because the
  # parcel has left, a moment later.
  class CancellationsController < ApplicationController
    def create
      render_order Order.find(params[:order_id]).request_cancellation(reason: "customer"), status: :accepted
    end
  end
end
