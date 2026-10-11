module Platform
  # The outbox's health, for a monitor that probes from outside the application. The relay, which
  # also says how many jobs wait, is itself a job on the very queue that may be down, so it can't
  # be the only alarm. Answers 503 once the oldest staged job has waited past StagedJob::STUCK_AFTER.
  class OutboxHealthController < ActionController::API
    def show
      oldest = StagedJob.minimum(:created_at)
      age = oldest ? (Time.current - oldest).round : 0

      render json: { staged_jobs: StagedJob.count, oldest_age_seconds: age }, status: age > StagedJob::STUCK_AFTER ? :service_unavailable : :ok
    end
  end
end
