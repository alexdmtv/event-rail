module Loyalty
  class AwardPointsJob < ApplicationJob
    subscribes_to Orders::Events::OrderDelivered

    def perform(event) = Entry.award(event)
  end
end
