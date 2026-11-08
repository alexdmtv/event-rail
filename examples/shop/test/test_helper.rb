ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
%w[ platform catalog payments fulfillment orders notifications loyalty ].each do |name|
  require_relative "../engines/#{name}/test/support/#{name}/test_support"
end

# So response.parsed_body parses problem details, the shape of every error answer, as JSON.
ActionDispatch::IntegrationTest.register_encoder :problem, response_parser: ->(body) { JSON.parse(body) }

module ActiveSupport
  class TestCase
    include ActiveJob::TestHelper
    include Platform::TestSupport

    # Each module's fixtures, for its own tables: the baseline every test starts from.
    self.fixture_paths = Dir[Rails.root.join("engines/*/test/fixtures")]
    fixtures :all

    parallelize(workers: :number_of_processors)

    setup { Platform::Traces.exporter.reset }

    teardown do
      Payments::TestSupport.reset_gateway
      Fulfillment::TestSupport.reset_carrier
    end
  end
end
