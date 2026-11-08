module Fulfillment
  # What other modules' tests and the host's may use of Fulfillment: the carrier's behaviour, set
  # in Fulfillment's terms, and readers that answer with values, never records, so Fulfillment can
  # change inside without breaking anyone else's tests. Configuring the carrier returns nil; readers
  # answer a mapped symbol, true or false, or the items asked for.
  module TestSupport
    SHIPMENTS = { "requested" => :requested, "dispatched" => :dispatched, "delivered" => :delivered, "cancelled" => :cancelled }.freeze
    PARCEL_RETURNS = { "expected" => :expected, "received" => :received }.freeze

    class << self
      # The carrier answers after the delay: at once, or after an hour so a test can act in between.
      def carrier_answers_after(delay) = (Carrier.adapter = Carrier::Fake.new(delay:)).then { nil }
      def carrier_answers_at_once = carrier_answers_after(0)
      def carrier_answers_after_an_hour = carrier_answers_after(1.hour)

      # Back to the carrier the environment chose.
      def reset_carrier = Carrier.adapter = nil

      # The carrier collects the parcels waiting for it, delivers those on their way, or brings
      # back those being returned, however long it was going to take, and Fulfillment announces
      # it; Fulfillment's own jobs do the work.
      def carrier_collects_parcels = Platform::TestSupport::Worker.perform_queued(DispatchJob).then { nil }
      def carrier_delivers_parcels = Platform::TestSupport::Worker.perform_queued(DeliveryJob).then { nil }
      def carrier_brings_back_parcels = Platform::TestSupport::Worker.perform_queued(ReturnArrivalJob).then { nil }

      # Where the parcel for the reference stands: nil (nothing asked), :requested, :dispatched,
      # :delivered or :cancelled.
      def shipment_status(reference) = shipment(reference)&.state&.then { |state| SHIPMENTS.fetch(state) }

      # Whether the parcel left the warehouse, whatever happened to it after.
      def dispatched?(reference) = shipment(reference)&.dispatched_at.present?

      # What Fulfillment was asked to ship, as { "sku" => quantity }; nil when nothing was asked.
      def shipment_items(reference) = shipment(reference)&.items&.transform_values(&:to_i)

      # Where a parcel coming back stands: nil (none), :expected or :received.
      def parcel_return_status(reference) = parcel_return(reference)&.state&.then { |state| PARCEL_RETURNS.fetch(state) }

      private
        def shipment(reference) = Shipment.find_by(reference: reference)
        def parcel_return(reference) = ParcelReturn.find_by(reference: reference)
    end
  end
end
