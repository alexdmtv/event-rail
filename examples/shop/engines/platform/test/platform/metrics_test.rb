require "test_helper"

module Platform
  class MetricsTest < ActiveSupport::TestCase
    class Refused < StandardError
      include FailedPrecondition
    end

    class ProbeJob < ApplicationJob
      def perform = nil
    end

    # An adapter whose monitoring system is down.
    class BrokenAdapter < Yabeda::BaseAdapter
      %i[ register! perform_counter_increment! perform_gauge_set! perform_histogram_measure! ].each do |method|
        define_method(method) { |*| raise "the monitoring system is down" }
      end
    end

    def stage = StagedJob.transaction { ProbeJob.stage }

    test "errors are counted by category and whether they were an answer" do
      Rails.error.report(Refused.new("no"))
      Rails.error.report(RuntimeError.new("broken"))

      counts = recorded(Yabeda.platform.errors_total)
      assert_equal 1, counts[{ category: "FailedPrecondition", expected: "true", source: "application" }]
      assert_equal 1, counts[{ category: "none", expected: "false", source: "application" }]
    end

    test "the outbox's backlog and its oldest job's age are read when the monitoring system asks" do
      refusing_enqueue { stage }
      assert_equal({ { job_class: ProbeJob.name } => 1 }, recorded(Yabeda.platform.staged_jobs_held_total))

      travel(1.minute) { Yabeda.collect! }

      assert_equal 1, recorded(Yabeda.platform.staged_jobs)[{}]
      assert_in_delta 60, recorded(Yabeda.platform.oldest_staged_job_age_seconds)[{}], 1
    end

    test "a monitoring system that fails never fails the code it measures" do
      Yabeda.register_adapter(:broken, Metrics::SafeAdapter.new(BrokenAdapter.new))

      reports = capture_error_reports { assert_nothing_raised { stage } }

      assert_equal 0, StagedJob.count, "staged and handed over as usual"
      assert reports.any? { |report| report.source == "platform.metrics" }
    ensure
      Yabeda.adapters.delete(:broken)
    end
  end
end
