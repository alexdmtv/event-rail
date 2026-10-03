module Orders
  module Events
    class Money < EventRail::Data
      attribute :amount_cents, :integer
      attribute :currency, :string

      validates :amount_cents, :currency, presence: true
    end
  end
end
