module Fulfillment
  # The parcel carrier, as Fulfillment sees it: the seam where an application plugs in its
  # carrier, and so part of Fulfillment's public surface. An adapter answers `pick_up`, `carry`
  # and `bring_back`. The example ships Carrier::Fake.
  module Carrier
    class << self
      attr_writer :adapter

      def current = @adapter || Fake.new
    end
  end
end
