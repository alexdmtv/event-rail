module Orders
  class LineItem < ApplicationRecord
    belongs_to :order

    def total_cents = quantity * unit_price_cents
  end
end
