module Fulfillment
  # What other modules' tests and the host's may use of Fulfillment: the carrier's behaviour, set
  # in Fulfillment's terms, and readers that answer with values, never records, so Fulfillment can
  # change inside without breaking anyone else's tests.
  module TestSupport
    # Plugs in the fake carrier, answering after the delay.
    def self.carrier_answering_after(delay) = Carrier.adapter = Carrier::Fake.new(delay:)

    # A carrier that answers at once, and one that takes an hour, so a test can act in between.
    def self.instant_carrier = carrier_answering_after(0)
    def self.slow_carrier = carrier_answering_after(1.hour)

    # Back to the carrier the environment chose.
    def self.reset_carrier = Carrier.adapter = nil

    # The carrier collects every parcel waiting for it, however long it was going to take.
    def self.carrier_collects_parcels = Platform::TestSupport::Worker.perform_queued(DispatchJob)

    # Where the parcel for the reference stands: nil (nothing asked), :requested, :dispatched,
    # :delivered or :cancelled.
    def self.shipment_status(reference) = shipment(reference)&.state&.to_sym

    # Whether the parcel left the warehouse, whatever happened to it after.
    def self.dispatched?(reference) = shipment(reference)&.dispatched_at.present?

    # Where a returned parcel stands: nil (no return), :expected or :received.
    def self.return_status(reference) = parcel_return(reference)&.state&.to_sym

    def self.shipment(reference) = Shipment.find_by(reference: reference)
    def self.parcel_return(reference) = ParcelReturn.find_by(reference: reference)
    private_class_method :shipment, :parcel_return
  end
end
