# Demonstration only: dials failures into the fake payment provider, the fake carrier and
# chosen jobs.
class FaultsController < ApplicationController
  RATES = Platform::FaultSettings::RATES

  def update
    if params[:job_class].present?
      Platform::FaultSettings.force_failures(ForceableJobs.find!(params[:job_class]), params.require(:count).to_i)
      back_to_console("#{params[:job_class]} will fail its next #{params[:count].to_i} runs.")
    else
      settings = Platform::FaultSettings.current
      settings.update!(RATES.to_h { |rate| [ rate, params.fetch(rate, 0).to_f / 100 ] }.merge(carrier_delay_seconds: params.fetch(:carrier_delay_seconds, 4).to_i))
      back_to_console("Faults updated.")
    end
  end
end
