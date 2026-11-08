module Fulfillment
  # What other modules' tests and the host's may use of Fulfillment: the carrier's behaviour, set
  # in Fulfillment's terms, and readers that answer with values, never records, so Fulfillment can
  # change inside without breaking anyone else's tests. Setup returns nothing; readers return symbols.
  module TestSupport
    SHIPMENTS = { "requested" => :requested, "dispatched" => :dispatched, "delivered" => :delivered, "cancelled" => :cancelled }.freeze
    PARCEL_RETURNS = { "expected" => :expected, "received" => :received }.freeze

    class << self
      # The carrier answers after the delay; at once, or after an hour, so a test can act in between.
      def carrier_answering_after(delay) = (Carrier.adapter = Carrier::Fake.new(delay:)).then { nil }
      def instant_carrier = carrier_answering_after(0)
      def slow_carrier = carrier_answering_after(1.hour)

      # Back to the carrier the environment chose.
      def reset_carrier = Carrier.adapter = nil

      # The carrier collects every parcel waiting for it, however long it was going to take.
      def carrier_collects_parcels = Platform::TestSupport::Worker.perform_queued(DispatchJob).then { nil }

      # Where the parcel for the reference stands: nil (nothing asked), :requested, :dispatched,
      # :delivered or :cancelled.
      def shipment_status(reference) = shipment(reference)&.state&.then { SHIPMENTS.fetch(_1) }

      # Whether the parcel left the warehouse, whatever happened to it after.
      def dispatched?(reference) = shipment(reference)&.dispatched_at.present?

      # Where a parcel coming back stands: nil (none), :expected or :received.
      def parcel_return_status(reference) = parcel_return(reference)&.state&.then { PARCEL_RETURNS.fetch(_1) }

      private
        def shipment(reference) = Shipment.find_by(reference: reference)
        def parcel_return(reference) = ParcelReturn.find_by(reference: reference)
    end
  end
end
