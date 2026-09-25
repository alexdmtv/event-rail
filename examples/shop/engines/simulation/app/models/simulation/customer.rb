module Simulation
  class Customer < ApplicationRecord
    def snapshot = Orders::Api::Customer.new(id: customer_id, name: name, email: email, address: address)
  end
end
