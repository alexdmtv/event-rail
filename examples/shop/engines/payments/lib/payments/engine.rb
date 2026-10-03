require_relative "../../../platform/lib/platform/engine"

module Payments
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Payments
    share_migrations
  end
end
