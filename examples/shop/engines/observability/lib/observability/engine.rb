require_relative "../../../platform/lib/platform/engine"
require_relative "recorder"

module Observability
  # Records how every flow in the shop unfolds, for the developer console: each event
  # published, each job enqueued in a flow and what caused it, and each attempt to perform
  # one. It listens only to instrumentation -- EventRail's notifications and Active Job's --
  # and reads EventRail's public context; nothing in the shop calls it, and no module depends
  # on it.
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Observability
    share_migrations

    config.after_initialize { Observability::Recorder.subscribe }
  end
end
