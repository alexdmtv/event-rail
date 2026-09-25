require_relative "../../../platform/lib/platform/engine"
require_relative "../../../catalog/lib/catalog/engine"
require_relative "../../../payments/lib/payments/engine"
require_relative "../../../fulfillment/lib/fulfillment/engine"

module Orders
  # Orders owns the order's lifecycle and every flow in the shop: it calls Catalog, Payments
  # and Fulfillment for the steps it needs, listens to what they report, and announces what
  # happens to orders for anyone who cares.
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Orders
    share_migrations
  end
end
