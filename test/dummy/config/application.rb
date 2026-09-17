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

    # app/services holds a subscriber declared outside the conventional app/events and
    # app/jobs roots on purpose: preparation must not discover it, and loading it later
    # must raise. Eager loading it at boot would raise during boot instead, which is the
    # correct production behavior but would hide what this fixture is for.
    config.to_prepare do
      Rails.autoloaders.main.do_not_eager_load(Rails.root.join("app/services").to_s)
    end

    # A prepare callback registered directly on the reloader runs before EventRail's, which
    # the add_to_prepare_blocks finisher registers later. That is the one place an
    # application can reach the window between a constant unload and EventRail's rebuild,
    # so the reload tests need it -- but only they do, hence the environment variable.
    if ENV["DUMMY_PREPARE_TOUCHES_EVENTS"] == "true"
      config.after_initialize do
        Rails.application.reloader.to_prepare(prepend: true) do
          Orders::OrderPlaced
          Orders::RecordOrderMetricsJob
        end
      end
    end
  end
end
