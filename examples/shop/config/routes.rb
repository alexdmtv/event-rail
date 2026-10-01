Rails.application.routes.draw do
  mount Orders::Engine, at: "/"

  get "up" => "rails/health#show", as: :rails_health_check
end
