require "test_helper"

module Platform
  class StagedJobTest < ActiveSupport::TestCase
    # A job that notes the flow it ran in.
    class ProbeJob < Platform::ApplicationJob
      cattr_accessor :runs, default: []

      def perform(label) = runs << [ label, job_id, EventRail::Current.correlation_id ]
    end

    # A job that declines to be enqueued.
    class DeclinedJob < ProbeJob
      before_enqueue { throw :abort }
    end

    setup { ProbeJob.runs = [] }

    def stage(label = "staged")
      EventRail.with_context(message_id: "checkout-k") do
        StagedJob.transaction { ProbeJob.stage_later(label) }
      end
    end

    test "a staged job is handed to the queue once its transaction commits, and runs in the flow it was staged in" do
      job = stage

      assert_equal 0, StagedJob.count
      perform_enqueued_jobs
      assert_equal [ [ "staged", job.job_id, "checkout-k" ] ], ProbeJob.runs
    end

    test "a rolled-back transaction stages nothing" do
      StagedJob.transaction do
        ProbeJob.stage_later("rolled back")
        raise ActiveRecord::Rollback
      end

      assert_equal 0, StagedJob.count
      assert_no_enqueued_jobs
    end

    test "a job the queue could not take at the commit is handed over by the relay" do
      job = refusing_enqueue { stage }
      assert_equal 1, StagedJob.count
      assert_no_enqueued_jobs

      relay_staged_jobs

      assert_equal 0, StagedJob.count
      perform_enqueued_jobs
      assert_equal [ [ "staged", job.job_id, "checkout-k" ] ], ProbeJob.runs, "the relayed job keeps its ID and its flow"
    end

    test "a job the queue declined without raising stays staged until the relay hands it over" do
      job = refusing_enqueue { stage }
      assert_equal 1, StagedJob.count
      assert_no_enqueued_jobs

      relay_staged_jobs

      assert_equal 0, StagedJob.count
      perform_enqueued_jobs
      assert_equal [ [ "staged", job.job_id, "checkout-k" ] ], ProbeJob.runs
    end

    test "a job whose own enqueue callback aborts is dropped, not retried" do
      EventRail.with_context(message_id: "checkout-k") do
        StagedJob.transaction { DeclinedJob.stage_later("declined") }
      end

      assert_equal 0, StagedJob.count
      assert_no_enqueued_jobs
    end

    test "a job handed over twice keeps its job ID" do
      job = stage
      # As if the first hand-over had crashed after enqueuing and before deleting its row.
      payload = enqueued_jobs.sole.except(:job, :args, :queue, :priority, :at)
      StagedJob.create!(job_id: job.job_id, job_class: ProbeJob.name, payload: payload, correlation_id: "checkout-k", created_at: 1.minute.ago)

      StagedJobRelayJob.perform_now

      assert_equal [ job.job_id ] * 2, enqueued_jobs.map { |enqueued| enqueued["job_id"] }
    end

    test "staging outside a transaction is refused" do
      error = assert_raises(ArgumentError) { ProbeJob.stage_later("alone") }
      assert_match(/perform_later/, error.message)
    end
  end
end
