module Platform
  # Hands to the queue every staged job whose immediate hand-over, right after its
  # transaction committed, was cut short -- by a crash, or a queue that could not accept it.
  # Run every second from config/recurring.yml. A scheduled chore outside every flow, so it
  # carries no EventRail context of its own; each job it hands over rejoins the flow it was
  # staged in.
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
