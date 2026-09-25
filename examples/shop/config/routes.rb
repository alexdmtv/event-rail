Rails.application.routes.draw do
  root "console#show"

  resource :simulation, only: :update
  resource :faults, only: :update

  resources :orders, only: %i[ index show new create ] do
    member do
      post :cancel
      post :return
    end
  end
  get "flows/:correlation_id", to: "flows#show", as: :flow
  get "architecture", to: "architecture#show"

  # The queue itself: subscriber deliveries are ordinary jobs, with their own queues and retries.
  mount MissionControl::Jobs::Engine, at: "/jobs"

  get "up" => "rails/health#show", as: :rails_health_check
end
