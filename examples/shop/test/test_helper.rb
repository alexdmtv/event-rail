ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/publication_recorder"
require_relative "support/scripted_gateway"
require_relative "support/shop_helpers"
require_relative "support/worker"

module ActiveSupport
  class TestCase
    include ActiveJob::TestHelper
    include PublicationRecorder
    include Worker

    parallelize(workers: :number_of_processors)

    teardown { Payments::Gateway.adapter = nil }
  end
end
