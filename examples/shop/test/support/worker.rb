# Works off the test queue the way a Solid Queue worker does: one job at a time, oldest
# first, each failure contained in its own job. Retries are scheduled in the future by
# retry_on; the worker does not wait for them, as if time had passed.
#
# Flow tests use this instead of performing jobs inline, because inline jobs run inside the
# enqueue that created them: a failing subscriber would raise out of the publisher that
# enqueued it, which is the opposite of how the shop behaves.
module Worker
  Failure = Data.define(:job_class, :error)

  # With due_only, jobs scheduled for later -- a slow carrier's next step -- stay queued.
  def work_off_queue(max_jobs: 1_000, due_only: false)
    failures = []
    max_jobs.times do
      index = queue_adapter.enqueued_jobs.index { |queued| !due_only || queued[:at].nil? || queued[:at] <= Time.current.to_f }
      job = index && queue_adapter.enqueued_jobs.delete_at(index) or return failures
      begin
        ActiveJob::Base.execute(job.stringify_keys.except("job", "args", "at", "queue", "priority"))
      rescue => error
        failures << Failure.new(job_class: job["job_class"], error: error)
      end
    end
    raise "the queue did not drain within #{max_jobs} jobs"
  end
end
