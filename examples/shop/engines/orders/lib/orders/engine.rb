# Its own bin/rails loads this file before the shop; the class body extends Platform::ModuleEngine.
require_relative "../../../platform/lib/platform/engine"

module Orders
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Orders
    share_migrations
  end
end
