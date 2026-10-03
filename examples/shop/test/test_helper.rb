ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
%w[ platform catalog payments fulfillment orders notifications loyalty ].each do |name|
  require_relative "../engines/#{name}/test/support/#{name}/test_support"
end
require_relative "support/publication_recorder"
require_relative "support/schedule"
require_relative "support/scripted_gateway"
require_relative "support/shop_helpers"
require_relative "support/worker"

# So response.parsed_body parses problem details, the shape of every error answer, as JSON.
ActionDispatch::IntegrationTest.register_encoder :problem, response_parser: ->(body) { JSON.parse(body) }

module ActiveSupport
  class TestCase
    include ActiveJob::TestHelper
    include PublicationRecorder
    include Schedule
    include Worker
    include Platform::TestSupport

    parallelize(workers: :number_of_processors)

    teardown do
      Payments::Gateway.adapter = nil
      Fulfillment::Carrier.adapter = nil
    end
  end
end
