module Fulfillment
  # The carrier seam: an adapter answers `pick_up`, `carry` and `bring_back`.
  module Carrier
    class << self
      attr_writer :adapter

      def current = @adapter || Fake.new
    end
  end
end
