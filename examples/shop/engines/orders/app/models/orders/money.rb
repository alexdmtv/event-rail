module Orders
  # An amount of one currency.
  Money = Data.define(:cents, :currency) do
    def self.zero(currency) = new(cents: 0, currency: currency)

    def +(other)
      raise ArgumentError, "cannot add #{other.currency} to #{currency}" unless other.currency == currency

      with(cents: cents + other.cents)
    end

    def *(factor) = with(cents: cents * factor)

    def to_s = format("€%.2f", cents / 100.0)
  end
end
