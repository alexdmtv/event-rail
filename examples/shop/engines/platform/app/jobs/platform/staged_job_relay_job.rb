module Platform
  # Not a Platform::ApplicationJob: it carries no EventRail context of its own, so each job it
  # hands over rejoins the flow it was staged in.
  class StagedJobRelayJob < ActiveJob::Base
    queue_as :default

    def perform
      StagedJob.overdue.find_each do |staged|
        staged.hand_over
      rescue => error
        staged.hold(error)
      end
    end
  end
end
