require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# The shop's modules, in dependency order.
require_relative "../engines/platform/lib/platform/engine"
require_relative "../engines/catalog/lib/catalog/engine"
require_relative "../engines/payments/lib/payments/engine"
require_relative "../engines/fulfillment/lib/fulfillment/engine"
require_relative "../engines/orders/lib/orders/engine"
require_relative "../engines/notifications/lib/notifications/engine"
require_relative "../engines/loyalty/lib/loyalty/engine"

module Shop
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    config.api_only = true

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Discovers every module's published events at boot, even one no subscriber references yet.
    config.event_rail.roots << "app/public"

    # A name, not the class: the class is reloadable application code.
    config.event_rail.stager = "Platform::StagedJob"

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
