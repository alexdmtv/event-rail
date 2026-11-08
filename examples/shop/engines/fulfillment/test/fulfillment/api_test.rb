require "test_helper"

module Fulfillment
  class ApiTest < ActiveSupport::TestCase
    # The fake carrier's jobs, standing in for its callbacks.
    CARRIER_JOBS = [ DispatchJob, DeliveryJob, ReturnArrivalJob ].freeze
    RECIPIENT = Api::Recipient.new(name: "Ada Lovelace", address: "12 St James's Square, London")

    def request_shipment = Api.request_shipment(reference: "ref-1", recipient: RECIPIENT, items: { "MUG" => 1 })
    def shipment = Shipment.find_by!(reference: "ref-1")

    test "a requested shipment is dispatched and then delivered" do
      published = record_publications { perform_enqueued_jobs(only: CARRIER_JOBS) { request_shipment } }

      assert_equal [ "fulfillment.shipment_dispatched", "fulfillment.shipment_delivered" ], published.map(&:event_type)
      assert_equal "delivered", shipment.state
      assert_match(/\ATRK-/, shipment.tracking_code)
      assert_equal({ reference: "ref-1", tracking_code: shipment.tracking_code }, published.first.payload.slice(:reference, :tracking_code))
      assert_equal [ { "MUG" => 1 }, "Ada Lovelace", "12 St James's Square, London" ], [ shipment.items, shipment.recipient_name, shipment.address ]
    end

    test "the carrier works on its own schedule" do
      Carrier.adapter = Carrier::Fake.new(delay: 30.seconds)

      request_shipment

      assert_enqueued_with(job: DispatchJob, args: [ "ref-1" ], at: 30.seconds.from_now)
      assert_equal "requested", shipment.state
    end

    test "requesting the same shipment twice ships it once" do
      published = record_publications { perform_enqueued_jobs(only: CARRIER_JOBS) { 2.times { request_shipment } } }

      assert_equal 1, Fulfillment::Shipment.count
      dispatches = published.select { |publication| publication.event_type == "fulfillment.shipment_dispatched" }
      assert_equal 1, dispatches.map(&:event_id).uniq.size, "a repeated dispatch must reuse the event identity"
    end

    test "a shipment cancelled before the carrier collects it never leaves" do
      Carrier.adapter = Carrier::Fake.new(delay: 30.seconds)
      request_shipment

      published = record_publications do
        Api.cancel_shipment(reference: "ref-1")
        Api.cancel_shipment(reference: "ref-1")
        work_off_queue(only: CARRIER_JOBS)
      end

      assert_empty published
      assert_equal "cancelled", shipment.state
    end

    test "a dispatched shipment cannot be cancelled" do
      Carrier.adapter = Carrier::Fake.new(delay: 30.seconds)
      request_shipment
      perform_enqueued_jobs(only: DispatchJob)

      assert_raises(AlreadyDispatched) { Api.cancel_shipment(reference: "ref-1") }
      assert_equal "dispatched", shipment.state
    end

    test "a request arriving after the cancellation does not revive the shipment" do
      Api.cancel_shipment(reference: "ref-1")

      published = record_publications { perform_enqueued_jobs(only: CARRIER_JOBS) { request_shipment } }

      assert_empty published
      assert_equal "cancelled", shipment.state
    end

    test "a dispatch retried after its delivery could not be scheduled still delivers" do
      Carrier.adapter = Carrier::Fake.new(delay: 0)
      request_shipment
      clear_enqueued_jobs
      # Commits the dispatch, fails to schedule the delivery, and retries later.
      refusing_enqueue(only: DeliveryJob) { DispatchJob.perform_now("ref-1") }
      assert_enqueued_jobs 1, only: DispatchJob
      assert_equal "dispatched", shipment.state

      work_off_queue(only: CARRIER_JOBS)

      assert_equal "delivered", shipment.state
    end

    test "an expected return is reported when the parcel arrives" do
      published = record_publications { perform_enqueued_jobs(only: CARRIER_JOBS) { Api.request_return_pickup(reference: "ref-1") } }

      assert_equal [ "fulfillment.return_received" ], published.map(&:event_type).uniq
    end
  end
end
