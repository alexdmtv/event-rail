module Fulfillment
  # The carrier seam: an adapter answers `pick_up`, `carry` and `bring_back`.
  module Carrier
    class << self
      # A test may plug in another adapter; nil goes back to the environment's choice.
      attr_writer :adapter

      # Built on first use, so a reload, which replaces this module, builds it again.
      def current = @adapter ||= build(Rails.configuration.fulfillment)

      private
        def build(config)
          case config.carrier
          when :fake then Fake.new(delay: config.fake_carrier_delay)
          else raise ArgumentError, "config.fulfillment.carrier names no carrier: #{config.carrier.inspect}"
          end
        end
    end
  end
end
