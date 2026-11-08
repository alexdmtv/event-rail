module Platform
  module TestSupport
    # Works off the queue as a worker does, one job at a time with each failure contained. Not
    # inline: an inline job's failure would raise out of the code that enqueued it.
    module Worker
      Failure = Data.define(:job_class, :error, :job)

      # Runs retries without waiting for them, as if time had passed, unless due_only. A module's
      # tests name their own jobs (only:); the host's flow tests run everything.
      def work_off_queue(max_jobs: 1_000, due_only: false, only: nil)
        failures = []
        Worker.drain(Worker.names(only), due_only:, max_jobs:) do |job|
          Worker.execute(job)
        rescue => error
          failures << Failure.new(job_class: job["job_class"], error: error, job: job)
        end
        failures
      end

      # Requeues failed jobs under the same IDs, as replaying them from the failed jobs does.
      def replay(*failures)
        failures.flatten.each { |failure| queue_adapter.enqueued_jobs << failure.job.except(:at) }
      end

      # Runs the job now, as one delivery would, and fails the test if it raised: perform_now hands
      # an error to the retry policy, which only schedules a retry, so the error would go unseen.
      def perform_once(job_class, *arguments)
        retried = []
        callback = ->(event) { retried << event.payload[:error] }
        ActiveSupport::Notifications.subscribed(callback, "enqueue_retry.active_job") { job_class.perform_now(*arguments) }
        flunk "#{job_class.name} raised #{retried.first.class}: #{retried.first.message}" if retried.any?
      end

      # Runs the queued jobs of these classes, due or not, until none is left, and only those: for
      # a module's test support, which names its own jobs so other modules' tests needn't.
      def self.perform_queued(*job_classes, max_jobs: 100)
        drain(names(job_classes), max_jobs:) { |job| execute(job) }
      end

      # nil means every job; an empty list names none, which is a mistake rather than everything.
      def self.names(job_classes)
        return if job_classes.nil?

        Array(job_classes).map(&:name).presence or raise ArgumentError, "no job named to run"
      end

      def self.drain(names, max_jobs:, due_only: false)
        queued = ActiveJob::Base.queue_adapter.enqueued_jobs
        runnable = ->(job) { (names.nil? || names.include?(job["job_class"])) && (!due_only || job[:at].nil? || job[:at] <= Time.current.to_f) }
        max_jobs.times do
          index = queued.index(&runnable) or return
          yield queued.delete_at(index)
        end
        raise "jobs still queued after #{max_jobs}" if queued.any?(&runnable)
      end

      def self.execute(job) = ActiveJob::Base.execute(job.stringify_keys.except("job", "args", "at", "queue", "priority"))
    end
  end
end
