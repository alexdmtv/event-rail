require_relative "../../../platform/lib/platform/engine"

module Catalog
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Catalog
    share_migrations
  end
end
