module Orders
  class LineItem < ApplicationRecord
    belongs_to :order
  end
end
