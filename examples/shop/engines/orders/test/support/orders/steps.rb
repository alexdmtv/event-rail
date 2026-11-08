module Orders
  # For Orders' own tests, which work with its records. They reach other modules only through
  # those modules' test support, as everyone else's tests do.
  module Steps
    CUSTOMER = TestSupport::CUSTOMER

    def checkout(**) = Order.find(TestSupport.checkout(**).id)
    def place(**) = Order.find(TestSupport.place_and_confirm(**).id)

    def available(sku) = Catalog::TestSupport.available(sku)
    def on_hand(sku) = Catalog::TestSupport.on_hand(sku)
  end
end
