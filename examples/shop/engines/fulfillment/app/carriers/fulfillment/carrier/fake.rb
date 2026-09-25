module Fulfillment
  module Carrier
    # A stand-in parcel carrier. It picks a shipment up, dispatches it and delivers it, one
    # scheduled job per step, with the delay between steps set from the developer console.
    # A real carrier would call back through a webhook; the scheduled jobs play that part.
    class Fake
      def pick_up(shipment)
        DispatchJob.perform_later_as("fulfillment-dispatch-#{shipment.reference}", shipment.reference, wait: delay)
      end

      def carry(shipment)
        DeliveryJob.perform_later_as("fulfillment-deliver-#{shipment.reference}", shipment.reference, wait: delay)
      end

      def bring_back(parcel_return)
        ReturnArrivalJob.perform_later_as("fulfillment-return-#{parcel_return.reference}", parcel_return.reference, wait: delay)
      end

      private
        def delay = Platform::FaultSettings.carrier_delay
    end
  end
end
