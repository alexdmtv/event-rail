require_relative "../../../platform/lib/platform/engine"
require_relative "../../../catalog/lib/catalog/engine"
require_relative "../../../orders/lib/orders/engine"

module Simulation
  # The outside world of the demonstration: customers placing, cancelling and returning
  # orders, and a supplier restocking the shelves. It uses the shop only through the same
  # public APIs the console uses -- it is a client, not part of the shop -- and nothing
  # depends on it.
  class Engine < ::Rails::Engine
    extend Platform::ModuleEngine

    isolate_namespace Simulation
    share_migrations

    # The simulator is off whenever the shop starts, even if it was left running when the
    # server stopped: restarting should not resume traffic nobody asked for. Its rate and
    # fractions are kept.
    config.after_initialize do
      Simulation::Engine.switch_simulator_off if defined?(Rails::Server)
    end

    def self.switch_simulator_off
      Simulation::Settings.where(running: true).update_all(running: false)
    rescue ActiveRecord::ActiveRecordError => error # no database yet: nothing to switch off
      Rails.logger.info("Simulator not switched off at boot: #{error.message}")
    end
  end
end
