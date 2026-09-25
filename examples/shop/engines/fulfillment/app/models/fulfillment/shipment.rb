module Fulfillment
  class Shipment < ApplicationRecord
    def dispatched_or_later? = state.in?(%w[ dispatched delivered ])
    def delivered? = state == "delivered"

    # Moves from `from` to `to` unless another process already did; true if this call did.
    def transition!(from:, to:, **attributes)
      moved = self.class.where(id: id, state: from).update_all(attributes.merge(state: to, updated_at: Time.current))
      reload
      moved == 1
    end
  end
end
