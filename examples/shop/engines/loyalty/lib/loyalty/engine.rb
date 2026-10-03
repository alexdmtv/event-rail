require_relative "../../../platform/lib/platform/engine"

module Loyalty
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Loyalty
    share_migrations
  end
end
