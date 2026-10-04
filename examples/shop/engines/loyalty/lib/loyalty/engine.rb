# Its own bin/rails loads this file before the shop; the class body extends Platform::ModuleEngine.
require_relative "../../../platform/lib/platform/engine"

module Loyalty
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Loyalty
    share_migrations
  end
end
