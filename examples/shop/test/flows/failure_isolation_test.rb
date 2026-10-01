require_relative "flow_test_case"

class FailureIsolationTest < FlowTestCase
  test "a Loyalty that fails every attempt leaves every order, payment and shipment untouched" do
    order, published = failing_runs("Loyalty::AwardPointsJob", 100) { place_and_settle }

    assert_equal "delivered", order.status
    assert_equal "captured", Payments::TestSupport.payment(order.reference).state
    assert_equal "delivered", Fulfillment::TestSupport.shipment(order.reference).state
    assert_equal %w[ delivered placed shipped ], notified_kinds(order)
    assert_equal 0, points(order)
    assert_equal [ "Loyalty::AwardPointsJob" ], @job_failures.map(&:job_class).uniq
    assert_one_flow(order, published)
  end

  test "a subscriber told to fail three times retries alone and then succeeds" do
    order = nil
    retries = failing_runs("Loyalty::AwardPointsJob", 3) { retries_by_job { order, = place_and_settle } }

    assert_equal({ "Loyalty::AwardPointsJob" => 3 }, retries)
    assert_equal 38, points(order)
    assert_empty @job_failures
  end

  # Every journey an order can take, with where it must end.
  JOURNEYS = {
    "delivered, then returned" => { ends: "refunded", then: :return },
    "cancelled before capture" => { ends: "cancelled", first: :cancel },
    "capture refused" => { ends: "cancelled", provider: { capture: [ :refuse ] } },
    "refund refused" => { ends: "needs_attention", provider: { refund: [ :refuse ] }, then: :return }
  }.freeze

  # Only a checkout that fails after authorizing voids through VoidJob; Orders' checkout test
  # covers that path.
  IN_NO_JOURNEY = %w[ Payments::VoidJob ].freeze

  test "any job failing twice is retried, and every order still ends where it should" do
    Catalog::TestSupport.receive_stock(sku: "MUG", quantity: 1_000)
    Catalog::TestSupport.receive_stock(sku: "TEA", quantity: 1_000)

    shop_jobs.each do |job|
      failing_runs(job, 2) do |remaining|
        JOURNEYS.each do |name, journey|
          Payments::Gateway.adapter = ScriptedGateway.new(**journey.fetch(:provider, {}))
          order = place
          Orders::TestSupport.request_cancellation(order.id) if journey[:first] == :cancel
          work_off_queue
          Orders::TestSupport.request_return(order.id) if journey[:then] == :return
          work_off_queue

          order = Orders::TestSupport.order(order.id)
          if job == "Orders::CancelJob" && journey[:first] == :cancel
            # A cancellation held up by its own failures loses the race to the carrier, as it
            # would in a real shop: Fulfillment refuses it, and the order is delivered.
            assert order.cancellation_refused_at, "#{name}, with #{job} failing twice"
            assert_equal "delivered", order.status
          else
            assert_equal journey[:ends], order.status, "#{name}, with #{job} failing twice"
          end
        end

        assert remaining.call < 2 || IN_NO_JOURNEY.include?(job), "no journey ran #{job}"
      end
    end
  end

  private
    # Every concrete job of the shop's own; jobs declared by tests are left out.
    def shop_jobs
      Rails.application.eager_load!
      Platform::ApplicationJob.descendants
        .select { |job| job.name && job.descendants.empty? && Object.const_source_location(job.name)&.first.to_s.exclude?("/test/") }
        .map(&:name).sort
    end
end
