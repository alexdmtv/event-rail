require "test_helper"

module Platform
  class StagedJobTest < ActiveSupport::TestCase
    # A job that notes the flow it ran in.
    class ProbeJob < Platform::ApplicationJob
      cattr_accessor :runs, default: []

      def perform(label) = runs << [ label, job_id, EventRail::Current.correlation_id ]
    end

    setup { ProbeJob.runs = [] }

    def stage(job_id = "probe-1", label = "staged")
      EventRail.with_context(message_id: "checkout-k") do
        StagedJob.transaction { ProbeJob.stage_later_as(job_id, label) }
      end
    end

    test "a staged job is handed to the queue once its transaction commits, and runs in the flow it was staged in" do
      stage

      assert_equal 0, StagedJob.count
      perform_enqueued_jobs
      assert_equal [ [ "staged", "probe-1", "checkout-k" ] ], ProbeJob.runs
    end

    test "a rolled-back transaction stages nothing" do
      StagedJob.transaction do
        ProbeJob.stage_later_as("probe-1", "rolled back")
        raise ActiveRecord::Rollback
      end

      assert_equal 0, StagedJob.count
      assert_no_enqueued_jobs
    end

    test "a job the queue could not take at the commit is handed over by the relay" do
      queue_adapter.define_singleton_method(:enqueue) { |*| raise "queue unavailable" }
      stage
      queue_adapter.singleton_class.remove_method(:enqueue)
      assert_equal 1, StagedJob.count
      assert_no_enqueued_jobs

      travel(StagedJob::GRACE + 1.second) { StagedJobRelayJob.perform_now }

      assert_equal 0, StagedJob.count
      perform_enqueued_jobs
      assert_equal [ [ "staged", "probe-1", "checkout-k" ] ], ProbeJob.runs, "the relayed job keeps its flow"
    ensure
      queue_adapter.singleton_class.remove_method(:enqueue) if queue_adapter.singleton_class.method_defined?(:enqueue, false)
    end

    test "a job handed over twice keeps its job ID" do
      stage
      # As if the first hand-over had crashed after enqueuing and before deleting its row.
      payload = enqueued_jobs.sole.except(:job, :args, :queue, :priority, :at)
      StagedJob.create!(job_id: "probe-1", job_class: ProbeJob.name, payload: payload, correlation_id: "checkout-k", created_at: 1.minute.ago)

      StagedJobRelayJob.perform_now

      assert_equal %w[ probe-1 probe-1 ], enqueued_jobs.map { |job| job["job_id"] }
    end

    test "staging outside a transaction is refused" do
      error = assert_raises(ArgumentError) { ProbeJob.stage_later_as("probe-1", "alone") }
      assert_match(/perform_later_as/, error.message)
    end
  end
end
