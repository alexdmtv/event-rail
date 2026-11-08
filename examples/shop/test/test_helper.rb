ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
Dir[File.expand_path("../engines/*/test/support/*/test_support.rb", __dir__)].sort.each { |file| require file }

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

    # A fault a test set and never met proves nothing: the test fails.
    teardown do
      assert_empty Payments::TestSupport.unused_provider_faults, "a fault set for the payment provider was never met"
    ensure
      Payments::TestSupport.reset_provider
      Fulfillment::TestSupport.reset_carrier
    end
  end
end
