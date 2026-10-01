Orders::Engine.routes.draw do
  defaults format: :json do
    resources :carts, only: :create do
      resource :order, only: :create, controller: "placements"
    end

    resources :orders, only: :show do
      resource :cancellation, only: :create
      resource :return, only: :create
    end
  end
end
