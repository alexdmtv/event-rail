require_relative "../../../platform/lib/platform/engine"
require_relative "../../../catalog/lib/catalog/engine"
require_relative "../../../payments/lib/payments/engine"
require_relative "../../../fulfillment/lib/fulfillment/engine"

module Orders
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Orders
    share_migrations
  end
end
