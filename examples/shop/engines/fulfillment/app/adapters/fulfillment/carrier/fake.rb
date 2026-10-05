module Fulfillment
  module Carrier
    # Its scheduled jobs, `delay` apart, stand in for a real carrier's webhook callbacks.
    class Fake
      def initialize(delay:)
        @delay = delay
      end

      def pick_up(shipment) = DispatchJob.perform_later!(shipment.reference, wait: @delay)
      def carry(shipment) = DeliveryJob.perform_later!(shipment.reference, wait: @delay)
      def bring_back(parcel_return) = ReturnArrivalJob.perform_later!(parcel_return.reference, wait: @delay)
    end
  end
end
