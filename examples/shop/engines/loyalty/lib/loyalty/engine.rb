require_relative "../../../platform/lib/platform/engine"

module Loyalty
  # Loyalty points: one per whole euro of a delivered order, taken back if the order is
  # refunded.
  #
  # Loyalty is the module the shop grew later. Adding it took this engine, one require in
  # config/application.rb and its package.yml depending on Orders' published events -- no
  # existing module changed. It learns everything from those events, and when it fails,
  # no order, payment or shipment waits for it.
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Loyalty
    share_migrations
  end
end
