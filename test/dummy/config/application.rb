require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "action_controller/railtie"
require "rails/test_unit/railtie"

require_relative "../engines/orders/lib/orders/engine"
require_relative "../engines/billing/lib/billing/engine"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.active_job.queue_adapter = ENV.fetch("ACTIVE_JOB_QUEUE_ADAPTER", "test").to_sym
    config.generators.system_tests = nil
  end
end
