module Simulation
  # Runs every second from config/recurring.yml, and does nothing while the simulator is off.
  #
  # It inherits from ActiveJob::Base, not Platform::ApplicationJob, on purpose. The simulator
  # plays customers outside the shop; each checkout it makes must start a new flow, exactly
  # as a browser's request does. A job carrying EventRail's context would instead make every
  # order it placed part of one long flow -- and EventRail refuses to start a new correlation
  # inside an existing one.
  class TickJob < ActiveJob::Base
    queue_as :simulation

    def perform
      settings = Settings.current
      Shoppers.new(settings).tick if settings.running?
    rescue => error
      Rails.logger.warn("Simulation tick failed: #{error.class}: #{error.message}")
    end
  end
end
