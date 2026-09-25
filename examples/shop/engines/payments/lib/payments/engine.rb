require_relative "../../../platform/lib/platform/engine"

module Payments
  # Card payments: authorize, capture, void and refund, against a payment provider behind
  # Payments::Gateway. Payments knows nothing about orders. It moves money for a caller's
  # reference and announces what happened to it.
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Payments
    share_migrations
  end
end
