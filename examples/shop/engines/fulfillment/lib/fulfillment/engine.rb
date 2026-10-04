# Its own bin/rails loads this file before the shop; the class body extends Platform::ModuleEngine.
require_relative "../../../platform/lib/platform/engine"

module Fulfillment
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Fulfillment
    share_migrations
  end
end
