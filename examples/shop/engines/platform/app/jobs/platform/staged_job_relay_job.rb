module Platform
  # Not a Platform::ApplicationJob: it carries no EventRail context of its own, so each job it
  # hands over rejoins the flow it was staged in.
  class StagedJobRelayJob < ActiveJob::Base
    queue_as :default

    def perform
      StagedJob.overdue.find_each do |staged|
        staged.hand_over
      rescue => error
        Rails.logger.warn("Staged job #{staged.job_id} not handed over yet: #{error.class}: #{error.message}")
      end
    end
  end
end
