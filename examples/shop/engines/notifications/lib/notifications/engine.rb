# Only for this module's own bin/rails (its generators), which loads this file before the shop:
# the class body needs Platform::ModuleEngine.
require_relative "../../../platform/lib/platform/engine"

module Notifications
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Notifications
    share_migrations
  end
end
