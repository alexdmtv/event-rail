require_relative "module_engine"

module Platform
  # The bottom layer every module may depend on: the base classes the other modules' own
  # base classes inherit from, and the settings the demonstration's fake providers read.
  # It depends on no other module.
  class Engine < ::Rails::Engine
    extend ModuleEngine

    isolate_namespace Platform
    share_migrations
  end
end
