require_relative "../../../platform/lib/platform/engine"

module Notifications
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Notifications
    share_migrations
  end
end
