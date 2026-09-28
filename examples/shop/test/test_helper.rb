ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/publication_recorder"
require_relative "support/scripted_gateway"
require_relative "support/shop_helpers"
require_relative "support/worker"
require_relative "../engines/platform/test/support/platform/faults"

module ActiveSupport
  class TestCase
    include ActiveJob::TestHelper
    include PublicationRecorder
    include Worker
    include Platform::Faults

    parallelize(workers: :number_of_processors)

    teardown { Payments::Gateway.adapter = nil }
  end
end
