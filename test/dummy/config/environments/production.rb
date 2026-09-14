require "active_support/core_ext/integer/time"
require "logger"

# Deliberately minimal. The generated production environment uses settings that moved
# or arrived between Rails 7.2 and 8.1 -- `ActiveSupport::TaggedLogging.logger` and
# `config.silence_healthcheck_path` among them -- and this fixture has to boot on every
# version in the advertised matrix. What the tests need from production is eager
# loading and no reloading.
Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true

  config.logger = ActiveSupport::TaggedLogging.new(Logger.new($stdout))
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "warn")
  config.log_tags = [ :request_id ]

  config.active_support.report_deprecations = false
  config.i18n.fallbacks = true
end
