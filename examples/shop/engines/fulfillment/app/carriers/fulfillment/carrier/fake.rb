module Fulfillment
  module Carrier
    # A stand-in parcel carrier. It picks a shipment up, dispatches it and delivers it, one
    # scheduled job per step, with the delay between steps set from the developer console.
    # A real carrier would call back through a webhook; the scheduled jobs play that part.
    class Fake
      def pick_up(shipment)
        DispatchJob.set(wait: delay).perform_later(shipment.reference)
      end

      def carry(shipment)
        DeliveryJob.set(wait: delay).perform_later(shipment.reference)
      end

      def bring_back(parcel_return)
        ReturnArrivalJob.set(wait: delay).perform_later(parcel_return.reference)
      end

      private
        def delay = Platform::FaultSettings.carrier_delay
    end
  end
end
