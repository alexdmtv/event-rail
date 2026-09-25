require_relative "../../../platform/lib/platform/engine"

module Fulfillment
  # Shipments and returns in transit, handed to a carrier. Fulfillment ships items to a
  # recipient for a caller's reference; it does not know what an order is.
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Fulfillment
    share_migrations
  end
end
