require "test_helper"

module Platform
  # The test environment has no queue database, so failed executions are stood in for.
  class RetryInterruptedJobsJobTest < ActiveSupport::TestCase
    FailedExecution = Struct.new(:exception_class, :retried) do
      def retry = self.retried = true
    end

    test "a job whose worker died is retried, and any other failure is left for a person" do
      interrupted = FailedExecution.new("SolidQueue::Processes::ProcessPrunedError", false)
      broken = FailedExecution.new("ActiveRecord::RecordNotFound", false)
      SolidQueue::FailedExecution.define_singleton_method(:find_each) { |&block| [ interrupted, broken ].each(&block) }

      RetryInterruptedJobsJob.perform_now

      assert interrupted.retried
      assert_not broken.retried
    ensure
      SolidQueue::FailedExecution.singleton_class.remove_method(:find_each) if SolidQueue::FailedExecution.singleton_class.method_defined?(:find_each, false)
    end

    test "the error Solid Queue records for a pruned worker's jobs is the one retried" do
      assert_equal SolidQueue::Processes::ProcessPrunedError.name, RetryInterruptedJobsJob::INTERRUPTED
    end
  end
end
