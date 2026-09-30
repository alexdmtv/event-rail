require "test_helper"
require "event_rail/test_helper"

# An event and two subscribers of its own, so EventRail.stage can be shown going through this
# stager without reaching into another module.
EventRail::TestHelper.declare do
  module Platform
    module StagedJobFixtures
      class Noticed < EventRail::Event
        event_type "platform_tests.noticed"
        version 1
        default_source "shop.platform_tests"

        attribute :reference, :string
        identity_by :reference
      end

      class NoticeJob < Platform::ApplicationJob
        cattr_accessor :runs, default: []

        subscribes_to Noticed

        def perform(event) = runs << [ self.class.name.demodulize, event.id, EventRail::Current.correlation_id ]
      end

      class OtherNoticeJob < Platform::ApplicationJob
        subscribes_to Noticed

        def perform(event) = NoticeJob.runs << [ self.class.name.demodulize, event.id, EventRail::Current.correlation_id ]
      end
    end
  end
end

module Platform
  class StagedJobTest < ActiveSupport::TestCase
    include EventRail::TestHelper
    # A job that notes the flow it ran in.
    class ProbeJob < Platform::ApplicationJob
      cattr_accessor :runs, default: []

      def perform(label) = runs << [ label, job_id, EventRail::Current.correlation_id ]
    end

    # A job that declines to be enqueued.
    class DeclinedJob < ProbeJob
      before_enqueue { throw :abort }
    end

    setup do
      ProbeJob.runs = []
      StagedJobFixtures::NoticeJob.runs = []
    end

    def stage(label = "staged")
      EventRail.with_context(message_id: "checkout-k") do
        StagedJob.transaction { ProbeJob.stage(label) }
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
        ProbeJob.stage("rolled back")
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
        StagedJob.transaction { DeclinedJob.stage("declined") }
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
      error = assert_raises(ArgumentError) { ProbeJob.stage("alone") }
      assert_match(/surrounding transaction/, error.message)
      assert_raises(ArgumentError) { StagedJob.stage([]) }
    end

    test "a list that fails part-way leaves none of its jobs, even when the failure is rescued and the transaction commits" do
      StagedJob.transaction do
        assert_raises(ActiveJob::SerializationError) { StagedJob.stage([ ProbeJob.new("fine"), ProbeJob.new(Object.new) ]) }
      end

      assert_equal 0, StagedJob.count
      assert_no_enqueued_jobs
    end

    test "a failure reading the staged rows back after the commit is left to the relay, not raised to the caller" do
      job = failing(StagedJob, :where, "database went away") do
        EventRail.with_context(message_id: "checkout-k") { StagedJob.transaction { ProbeJob.stage("staged") } }
      end
      assert_equal 1, StagedJob.count
      assert_no_enqueued_jobs

      relay_staged_jobs
      perform_enqueued_jobs

      assert_equal [ [ "staged", job.job_id, "checkout-k" ] ], ProbeJob.runs
    end

    # --- EventRail.stage goes through the same stager ---------------------------------

    test "a staged event reaches both subscribers after the commit, with its ID and the flow it was staged in" do
      staged = with_subscribers(StagedJobFixtures::NoticeJob, StagedJobFixtures::OtherNoticeJob) do
        EventRail.with_context(message_id: "checkout-k") do
          StagedJob.transaction { EventRail.stage(StagedJobFixtures::Noticed.new(reference: "n-1")) }
        end.tap do
          assert_equal 0, StagedJob.count
          perform_enqueued_jobs
        end
      end

      assert_equal [ [ "NoticeJob", staged.id, "checkout-k" ], [ "OtherNoticeJob", staged.id, "checkout-k" ] ],
        StagedJobFixtures::NoticeJob.runs.sort
    end

    test "a staged event whose transaction rolls back is delivered to nobody" do
      with_subscribers(StagedJobFixtures::NoticeJob, StagedJobFixtures::OtherNoticeJob) do
        StagedJob.transaction do
          EventRail.stage(StagedJobFixtures::Noticed.new(reference: "n-1"))
          raise ActiveRecord::Rollback
        end

        assert_equal 0, StagedJob.count
        assert_no_enqueued_jobs
      end
    end

    test "a staged event the queue could not take at the commit is delivered by the relay" do
      with_subscribers(StagedJobFixtures::NoticeJob, StagedJobFixtures::OtherNoticeJob) do
        staged = refusing_enqueue { StagedJob.transaction { EventRail.stage(StagedJobFixtures::Noticed.new(reference: "n-1")) } }
        assert_equal 2, StagedJob.count

        relay_staged_jobs
        perform_enqueued_jobs

        assert_equal 0, StagedJob.count
        assert_equal [ staged.id ] * 2, StagedJobFixtures::NoticeJob.runs.map(&:second)
      end
    end
  end
end
