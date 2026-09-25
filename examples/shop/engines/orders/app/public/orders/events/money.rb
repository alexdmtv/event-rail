module Orders
  module Events
    # An amount with its currency, as version 2 of OrderPlaced and the later order events
    # carry it.
    class Money < EventRail::Data
      attribute :amount_cents, :integer
      attribute :currency, :string

      validates :amount_cents, :currency, presence: true
    end
  end
end
