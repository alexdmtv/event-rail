module Orders
  module Events
    class LineItem < EventRail::Data
      attribute :sku, :string
      attribute :name, :string
      attribute :quantity, :integer
      attribute :unit_price_cents, :integer
    end
  end
end
