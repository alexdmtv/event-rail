module Orders
  class CartsController < ApplicationController
    def create
      cart = Cart.open(customer: customer, items: params.expect(items: {}))
      render status: :created, json: { id: cart.id, items: cart.items.map { |item| { sku: item.sku, quantity: item.quantity } } }
    end

    private
      # The shop has no customer module: the client says who is buying.
      def customer
        details = params.expect(customer: %i[ id name email address ])
        Api::Customer.new(id: details[:id], name: details[:name], email: details[:email], address: details[:address])
      end
  end
end
