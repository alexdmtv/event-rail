# Only for this module's own bin/rails (its generators), which loads this file before the shop:
# the class body needs Platform::ModuleEngine.
require_relative "../../../platform/lib/platform/engine"

module Fulfillment
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Fulfillment
    share_migrations

    # Each environment chooses the carrier (config.fulfillment.carrier). Building it here fails the boot,
    # and every reload, when the choice is missing or unknown.
    config.fulfillment = ActiveSupport::OrderedOptions.new
    config.to_prepare { Fulfillment::Carrier.current }
  end
end
