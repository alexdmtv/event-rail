class ConsoleController < ApplicationController
  def show
    @simulation = Simulation::Api.state
    @faults = Platform::FaultSettings.current
    @feed = Observability::Api.recent_publications(limit: 25)
    @counts = Orders::Api.count_by_state
    @forceable_jobs = ForceableJobs.names
  end
end
