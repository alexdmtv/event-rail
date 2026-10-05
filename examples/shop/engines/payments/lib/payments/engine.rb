# Only for this module's own bin/rails (its generators), which loads this file before the shop:
# the class body needs Platform::ModuleEngine.
require_relative "../../../platform/lib/platform/engine"

module Payments
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Payments
    share_migrations

    # Each environment chooses the gateway (config.payments.gateway). Building it here fails the boot,
    # and every reload, when the choice is missing or unknown.
    config.payments = ActiveSupport::OrderedOptions.new
    config.to_prepare { Payments::Gateway.current }
  end
end
