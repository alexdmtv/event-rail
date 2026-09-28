module Orders
  class CartItem < ApplicationRecord
    belongs_to :cart
  end
end
