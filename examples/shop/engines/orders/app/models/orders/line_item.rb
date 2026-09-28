module Orders
  class LineItem < ApplicationRecord
    belongs_to :order

    def total = Money.new(cents: quantity * unit_price_cents, currency: order.currency)
  end
end
