module Loyalty
  class RevokePointsJob < ApplicationJob
    subscribes_to Orders::Events::OrderRefunded

    def perform(event)
      Entry.record(event, kind: "revoke", points: -Entry.points_for(event.total))
    end
  end
end
