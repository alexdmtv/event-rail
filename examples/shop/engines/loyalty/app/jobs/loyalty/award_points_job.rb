module Loyalty
  class AwardPointsJob < ApplicationJob
    subscribes_to Orders::Events::OrderDelivered

    def perform(event)
      Entry.record(event, kind: "award", points: Entry.points_for(event.total))
    end
  end
end
