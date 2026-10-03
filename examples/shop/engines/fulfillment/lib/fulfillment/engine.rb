require_relative "../../../platform/lib/platform/engine"

module Fulfillment
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Fulfillment
    share_migrations
  end
end
