# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
require "rails/test_help"
require "minitest/mock"

# A Rails deprecation the library itself triggers is a defect on the compatibility
# floor, not a warning to scroll past: it becomes a removal on the next major. The
# Rails 7.2 `to_time` deprecation is the concrete case, and it only shows up on that
# appraisal, so the gate has to be on for every run rather than checked by eye.
ActiveSupport.deprecator.behavior = :raise

# The internal namespace is a private constant, which is the right default for
# application code and the wrong one for the tests that have to reach the encoder,
# the execution stack, and the publication path directly.
EventRailInternal = EventRail.const_get(:Internal)

class ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end
end
