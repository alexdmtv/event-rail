require_relative "../../../platform/lib/platform/engine"

module Catalog
  # Products, their prices and their stock. Catalog knows nothing about orders: it quotes,
  # reserves and releases stock for whoever asks, keyed by the caller's reservation ID.
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Catalog
    share_migrations
  end
end
