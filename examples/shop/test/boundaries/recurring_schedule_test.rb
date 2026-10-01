require "test_helper"

# Every task in config/recurring.yml names a job that exists, or a command, and a schedule Solid
# Queue can parse. Solid Queue refuses to start with an invalid schedule; this finds a renamed
# job in CI rather than at deploy.
class RecurringScheduleTest < ActiveSupport::TestCase
  test "the recurring schedule is valid" do
    assert_empty schedule_problems
  end
end
