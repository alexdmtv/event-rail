module Catalog
  # Not enough of a product is available to hold.
  class OutOfStock < Error
    include Platform::FailedPrecondition

    attr_reader :sku

    def initialize(sku)
      @sku = sku
      super("#{sku} is out of stock")
    end
  end
end
