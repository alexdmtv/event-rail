require_relative "../../../platform/lib/platform/engine"

module Notifications
  # Tells customers what happens to their orders. It learns everything from Orders' published
  # events -- each carries the customer's name and email -- and nothing in the shop knows it
  # exists: removing it would change no other module.
  #
  # Notifications are recorded rather than emailed, so the example needs no mail setup.
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Notifications
    share_migrations
  end
end
