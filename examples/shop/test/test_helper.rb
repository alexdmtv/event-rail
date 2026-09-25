ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/publication_recorder"
require_relative "support/scripted_gateway"
require_relative "support/shop_helpers"

module ActiveSupport
  class TestCase
    include ActiveJob::TestHelper
    include PublicationRecorder

    parallelize(workers: :number_of_processors)

    teardown { Payments::Gateway.adapter = nil }
  end
end
