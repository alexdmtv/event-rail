module Platform
  # Not a Platform::ApplicationJob: it carries no EventRail context of its own, so each job it
  # hands over rejoins the flow it was staged in.
  class StagedJobRelayJob < ActiveJob::Base
    queue_as :default

    def perform
      announce_backlog
      StagedJob.overdue.find_each do |staged|
        staged.hand_over
      rescue => error
        staged.hold(error)
      end
    end

    private
      # Jobs the code that staged them didn't manage to hand over, and how long the oldest has
      # waited: a log platform alerts when that age keeps growing. Said only while there are some.
      def announce_backlog
        oldest = StagedJob.overdue.minimum(:created_at) or return

        Rails.event.notify("platform.outbox_backlog", count: StagedJob.overdue.count, oldest_age_seconds: (Time.current - oldest).round)
      end
  end
end
