require_relative "../../../platform/lib/platform/engine"
require_relative "../../../catalog/lib/catalog/engine"
require_relative "../../../orders/lib/orders/engine"

module Simulation
  # The outside world of the demonstration: customers placing, cancelling and returning
  # orders, and a supplier restocking the shelves. It uses the shop only through the same
  # public APIs the console uses -- it is a client, not part of the shop -- and nothing
  # depends on it.
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Simulation
    share_migrations
  end
end
