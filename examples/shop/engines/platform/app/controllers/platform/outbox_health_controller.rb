module Platform
  # The outbox's health, for a monitor that probes from outside the application. The relay, which
  # also says how many jobs wait, is itself a job on the very queue that may be down, so it can't
  # be the only alarm. Answers 503 once the oldest waiting job has waited past
  # StagedJob::STUCK_AFTER. Parked jobs, whose class no longer exists, are counted apart: they were
  # reported, and would otherwise hold the check at 503 until someone removes them.
  class OutboxHealthController < ActionController::API
    def show
      oldest = StagedJob.waiting.minimum(:created_at)
      age = oldest ? (Time.current - oldest).round : 0

      render json: { staged_jobs: StagedJob.waiting.count, oldest_age_seconds: age, parked: StagedJob.where.not(parked_at: nil).count },
        status: age > StagedJob::STUCK_AFTER ? :service_unavailable : :ok
    end
  end
end
