class SimulationsController < ApplicationController
  def update
    case params[:command]
    when "start" then Simulation::Api.start
    when "stop" then Simulation::Api.stop
    else
      Simulation::Api.configure(
        orders_per_minute: params.require(:orders_per_minute).to_i,
        cancel_rate: percent(:cancel_rate), return_rate: percent(:return_rate)
      )
    end
    back_to_console(simulation_notice)
  end

  private
    def percent(name) = params.require(name).to_f / 100

    def simulation_notice
      state = Simulation::Api.state
      state.running ? "Simulating #{state.orders_per_minute} orders a minute." : "Simulator stopped."
    end
end
