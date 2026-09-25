class ArchitectureController < ApplicationController
  def show
    @graph = PackageGraph.load(Rails.root)
    @wiring = Observability::Api.wiring
  end
end
