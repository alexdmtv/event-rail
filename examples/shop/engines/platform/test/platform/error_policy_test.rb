require "test_helper"

module Platform
  class ErrorPolicyTest < ActiveSupport::TestCase
    class Refused < StandardError
      include FailedPrecondition
    end

    class Down < StandardError
      include Unavailable
    end

    class LostRace < StandardError
      include Aborted
    end

    class ProbeJob < ApplicationJob
      def perform(error_class) = raise(error_class.constantize.new)
    end

    # Fails as Active Job does when the database is briefly unreachable while loading arguments.
    class OrphanedJob < ApplicationJob
      def perform
        raise ActiveRecord::ConnectionNotEstablished
      rescue ActiveRecord::ConnectionNotEstablished
        raise ActiveJob::DeserializationError
      end
    end

    test "an error's category is the module it includes, or the one listed for a Rails error" do
      assert_equal FailedPrecondition, ErrorCategory.of(Refused.new)
      assert_equal NotFound, ErrorCategory.of(ActiveRecord::RecordNotFound.new)
      assert_equal Aborted, ErrorCategory.of(ActiveRecord::Deadlocked.new)
      assert_nil ErrorCategory.of(RuntimeError.new)
    end

    test "a job whose outcome went unhandled fails at once, without a retry" do
      [ Refused, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid ].each do |error|
        assert_raises(error) { ProbeJob.perform_now(error.name) }
        assert_no_enqueued_jobs only: ProbeJob
      end
    end

    test "a temporary failure, a lost race and an unclassified error are retried" do
      [ Down, LostRace, RuntimeError ].each do |error|
        ProbeJob.perform_now(error.name)

        assert_enqueued_jobs 1, only: ProbeJob
        clear_enqueued_jobs
      end
    end

    test "a lost race is retried sooner than a temporary failure" do
      ProbeJob.perform_now(LostRace.name)
      soon = enqueued_jobs.sole[:at]
      clear_enqueued_jobs
      ProbeJob.perform_now(Down.name)

      assert_operator soon, :<, enqueued_jobs.sole[:at]
    end

    test "a job whose arguments cannot be loaded is retried, not discarded" do
      OrphanedJob.perform_now

      assert_enqueued_jobs 1, only: OrphanedJob
    end
  end
end
