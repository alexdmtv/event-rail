module Orders
  class CancellationsController < ApplicationController
    def create
      render_order Order.find(params[:order_id]).request_cancellation(reason: "customer"), status: :accepted
    end
  end
end
