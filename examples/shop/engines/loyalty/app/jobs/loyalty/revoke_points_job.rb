module Loyalty
  class RevokePointsJob < ApplicationJob
    subscribes_to Orders::Events::OrderRefunded

    def perform(event)
      Entry.revoke(event)
    end
  end
end
