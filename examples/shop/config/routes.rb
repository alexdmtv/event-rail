Rails.application.routes.draw do
  root "console#show"

  resource :simulation, only: :update
  resource :faults, only: :update

  # A cart is filled in one form, then placed: placing a cart again returns its order.
  resources :carts, only: %i[ new create show ] do
    post :order, on: :member
  end
  resources :orders, only: %i[ index show ] do
    member do
      post :cancellation
      post :return
    end
  end
  get "flows/:correlation_id", to: "flows#show", as: :flow
  get "architecture", to: "architecture#show"

  # The queue itself: subscriber deliveries are ordinary jobs, with their own queues and retries.
  mount MissionControl::Jobs::Engine, at: "/jobs"

  get "up" => "rails/health#show", as: :rails_health_check
end
