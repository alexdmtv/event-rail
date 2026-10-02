module Orders
  class CartsController < ApplicationController
    def create
      cart = Cart.open(params.permit(:customer_id, :customer_name, :customer_email, :shipping_address, items: %i[ sku quantity ]))
      render status: :created, json: { id: cart.id, items: cart.items.map { |item| { sku: item.sku, quantity: item.quantity } } }
    end
  end
end
