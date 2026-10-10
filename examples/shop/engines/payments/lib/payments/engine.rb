# Only for this module's own bin/rails (its generators), which loads this file before the shop:
# the class body needs Platform::ModuleEngine.
require_relative "../../../platform/lib/platform/engine"
require_relative "metrics"

module Payments
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Payments
    share_migrations

    # Each environment chooses the gateway (config.payments.gateway). Building it here fails the boot,
    # and every reload, when the choice is missing or unknown.
    config.payments = ActiveSupport::OrderedOptions.new
    config.to_prepare { Payments::Gateway.current }

    # Every call to the provider is a span, with its operation and outcome (Payments::Gateway.call),
    # as well as a metric (Payments::Metrics).
    Platform::Traces.span "call_gateway.payments"
  end
end
