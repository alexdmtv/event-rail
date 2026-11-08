module Platform
  module TestSupport
    # Works off the queue as a worker does, one job at a time with each failure contained. Not
    # inline: an inline job's failure would raise out of the code that enqueued it.
    module Worker
      Failure = Data.define(:job_class, :error, :job)

      # Runs retries without waiting for them, as if time had passed, unless due_only.
      def work_off_queue(max_jobs: 1_000, due_only: false)
        failures = []
        max_jobs.times do
          index = queue_adapter.enqueued_jobs.index { |queued| !due_only || queued[:at].nil? || queued[:at] <= Time.current.to_f }
          job = index && queue_adapter.enqueued_jobs.delete_at(index) or return failures
          begin
            ActiveJob::Base.execute(job.stringify_keys.except("job", "args", "at", "queue", "priority"))
          rescue => error
            failures << Failure.new(job_class: job["job_class"], error: error, job: job)
          end
        end
        raise "the queue did not drain within #{max_jobs} jobs"
      end

      # Requeues failed jobs under the same IDs, as replaying them from the failed jobs does.
      def replay(*failures)
        failures.flatten.each { |failure| queue_adapter.enqueued_jobs << failure.job.except(:at) }
      end

      # Repeats until no due job is left, since due jobs enqueue more; later jobs stay queued.
      def perform_due_jobs
        perform_enqueued_jobs(at: Time.current) while enqueued_jobs.any? { |job| job[:at].nil? || job[:at] <= Time.current.to_f }
      end

      # Runs the queued jobs of these classes, due or not, until none is left, and only those; for
      # a module's test support, which names its own jobs so other modules' tests needn't.
      def self.perform_queued(*job_classes, max_jobs: 100)
        names = job_classes.map(&:name)
        queued = ActiveJob::Base.queue_adapter.enqueued_jobs
        max_jobs.times do
          index = queued.index { |job| names.include?(job["job_class"]) } or return
          ActiveJob::Base.execute(queued.delete_at(index).stringify_keys.except("job", "args", "at", "queue", "priority"))
        end
        raise "#{names.join(", ")} still queued after #{max_jobs} jobs"
      end
    end
  end
end
