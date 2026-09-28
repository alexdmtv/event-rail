module Orders
  # How many of a product: a whole number above zero, given as an Integer or as the digits a
  # form submits. Anything else is refused on construction.
  Quantity = Data.define(:count) do
    def self.parse(input)
      count = case input
      when Integer then input
      when String then Integer(input, 10) if input.strip.match?(/\A\d+\z/)
      end
      raise InvalidQuantity, "#{input.inspect} is not a quantity" unless count&.positive?

      new(count: count)
    end
  end
end
