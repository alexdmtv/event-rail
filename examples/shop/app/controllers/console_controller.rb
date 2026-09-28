class ConsoleController < ApplicationController
  def show
    @simulation = Simulation::Api.state
    @faults = Platform::FaultSettings.current
    @feed = Observability::Api.recent_publications(limit: 25)
    @counts = Orders::Api.status_counts
    @forceable_jobs = ForceableJobs.names
  end
end
