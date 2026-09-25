require "test_helper"

module Fulfillment
  class ApiTest < ActiveSupport::TestCase
    RECIPIENT = Api::Recipient.new(name: "Ada Lovelace", address: "12 St James's Square, London")

    def request_shipment = Api.request_shipment(reference: "ref-1", recipient: RECIPIENT, items: { "MUG" => 1 })

    test "a requested shipment is dispatched and then delivered" do
      published = record_publications { perform_enqueued_jobs { request_shipment } }

      assert_equal [ "fulfillment.shipment_dispatched", "fulfillment.shipment_delivered" ], published.map(&:event_type)
      shipment = Api.shipment("ref-1")
      assert_equal "delivered", shipment.state
      assert_match(/\ATRK-/, shipment.tracking_code)
    end

    test "the carrier works on its own schedule" do
      Platform::FaultSettings.current.update!(carrier_delay_seconds: 30)

      request_shipment

      assert_enqueued_with(job: DispatchJob, args: [ "ref-1" ], at: 30.seconds.from_now)
      assert_equal "requested", Api.shipment("ref-1").state
    end

    test "requesting the same shipment twice ships it once" do
      published = record_publications { perform_enqueued_jobs { 2.times { request_shipment } } }

      assert_equal 1, Fulfillment::Shipment.count
      dispatches = published.select { |publication| publication.event_type == "fulfillment.shipment_dispatched" }
      assert_equal 1, dispatches.map(&:event_id).uniq.size, "a repeated dispatch must reuse the event identity"
    end

    test "an expected return is reported when the parcel arrives" do
      published = record_publications { perform_enqueued_jobs { Api.expect_return(reference: "ref-1") } }

      assert_equal [ "fulfillment.return_received" ], published.map(&:event_type).uniq
    end

    test "shipments are looked up for many references at once" do
      request_shipment

      shipments = Api.shipments(%w[ ref-1 ref-2 ])

      assert_equal [ "ref-1" ], shipments.keys
      assert_equal "requested", shipments["ref-1"].state
    end
  end
end
