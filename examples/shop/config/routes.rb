Rails.application.routes.draw do
  mount Orders::Engine, at: "/"

  get "up" => "rails/health#show", as: :rails_health_check
  get "up/outbox" => "platform/outbox_health#show", as: :outbox_health_check
end
