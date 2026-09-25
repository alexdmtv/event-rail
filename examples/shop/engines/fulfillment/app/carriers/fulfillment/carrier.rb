module Fulfillment
  # The parcel carrier, as Fulfillment sees it. The example ships Carrier::Fake.
  module Carrier
    def self.current = Fake.new
  end
end
