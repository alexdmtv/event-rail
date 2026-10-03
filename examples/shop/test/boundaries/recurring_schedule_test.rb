require "test_helper"

# Solid Queue refuses to start with an invalid schedule; this finds a renamed job in CI, not at deploy.
class RecurringScheduleTest < ActiveSupport::TestCase
  test "the recurring schedule is valid" do
    assert_empty schedule_problems
  end
end
