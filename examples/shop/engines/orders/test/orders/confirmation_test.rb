require "test_helper"
require_relative "../support/order_records"

module Orders
  class ConfirmationTest < ActiveSupport::TestCase
    include ShopHelpers
    include OrderRecords

    setup { stock_shelves }

    test "confirming holds the stock, authorizes the card, and asks for the capture" do
      order = place

      assert_equal "confirmed", order.state
      assert_equal 8, available("MUG")
      assert_equal "authorized", Payments::Api.payment(order.reference).state
      assert_enqueued_jobs 1, only: ->(job) { job.fetch(:job).name == "Payments::CaptureJob" }
    end

    test "an out-of-stock item cancels the order with the reason, and nothing stays held" do
      published = record_publications { @order = place(items: { "TEA" => 1, "MUG" => 11 }) }

      assert_equal "cancelled", @order.state
      assert_equal "MUG is out of stock", @order.cancel_reason
      assert_equal 10, available("TEA")
      assert_nil Payments::Api.payment(@order.reference)
      assert_equal %w[ orders.order_cancelled orders.order_placed ], published.map(&:event_type).sort
    end

    test "a declined card cancels the order and gives its stock back" do
      Payments::Gateway.adapter = ScriptedGateway.new(authorize: [ :refuse ])

      order = place

      assert_equal "cancelled", order.state
      assert_match(/\Apayment declined/, order.cancel_reason)
      assert_equal 10, available("MUG")
      assert_nil Payments::Api.payment(order.reference)
    end

    test "a payment provider that does not answer is retried until it does; no count of attempts gives up" do
      Payments::Gateway.adapter = gateway = ScriptedGateway.new(authorize: [ :timeout ] * 3)
      order = checkout

      work_off_queue

      assert_equal 4, gateway.calls[:authorize]
      assert_equal "confirmed", order_record(order).state
    end

    test "confirming interrupted after the reservation reserves once when it runs again" do
      order = checkout
      failing(Payments::Api, :authorize) { perform_enqueued_jobs(only: ConfirmJob) }
      assert_equal "placed", order_record(order).state

      work_off_queue

      assert_equal "delivered", order_record(order).status
      assert_equal 8, on_hand("MUG")
    end

    test "confirming interrupted after the authorization is confirmed when it runs again, with one authorization" do
      Payments::Gateway.adapter = gateway = ScriptedGateway.new
      order = checkout
      interrupting_after(Payments::Api, :authorize) { perform_enqueued_jobs(only: ConfirmJob) }
      assert_equal "placed", order_record(order).state

      work_off_queue

      assert_equal "delivered", order_record(order).status
      assert_equal 1, gateway.calls[:authorize]
    end

    test "confirming interrupted after the order is confirmed asks for the capture when it runs again" do
      order = checkout
      failing(Payments::Api, :request_capture) { perform_enqueued_jobs(only: ConfirmJob) }
      assert_equal "confirmed", order_record(order).state

      work_off_queue

      assert_equal "delivered", order_record(order).status
    end

    test "every run announces the placement under the same identity" do
      order = checkout
      first = record_publications { failing(Payments::Api, :request_capture) { perform_enqueued_jobs(only: ConfirmJob) } }
      again = record_publications { work_off_queue }

      placed = (first + again).select { |publication| publication.event_type == "orders.order_placed" }
      assert_equal 2, placed.size
      assert_equal 1, placed.map(&:event_id).uniq.size
      assert_equal 2, placed.first.event_version
      assert_equal "delivered", order_record(order).status
    end

    test "a confirmation handed to the queue twice announces the order under one event identity" do
      checkout
      # As if the first hand-over had crashed after enqueuing and before deleting its row.
      staged = enqueued_jobs.sole.except(:job, :args, :queue, :priority, :at)
      Platform::StagedJob.create!(job_id: staged["job_id"], job_class: ConfirmJob.name, payload: staged, created_at: 1.minute.ago)
      Platform::StagedJobRelayJob.perform_now
      assert_equal 2, enqueued_jobs.count { |job| job["job_class"] == ConfirmJob.name }

      published = record_publications { work_off_queue }

      placed = published.select { |publication| publication.event_type == "orders.order_placed" }
      assert_equal 1, placed.map(&:event_id).uniq.size
    end
  end
end
