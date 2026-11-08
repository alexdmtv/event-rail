require "test_helper"

# A flow test runs every module's jobs, as workers would, and checks what each module ended up
# with through its test support.
class FlowTestCase < ActiveSupport::TestCase
  setup do
    Fulfillment::TestSupport.carrier_answers_at_once
    @shelves = %w[ MUG TEA ].index_with { |sku| Catalog::TestSupport.on_hand(sku) }
  end

  private
    def place_and_settle(**checkout_options)
      order = nil
      publications = record_publications do
        order = Orders::TestSupport.checkout(**checkout_options)
        @job_failures = work_off_queue
      end
      [ Orders::TestSupport.order(order.id), publications ]
    end

    def settle = record_publications { @job_failures = work_off_queue }

    # Units of the product that left the shelves since the test began, and units orders hold now,
    # without knowing how many Catalog had.
    def shipped(sku) = @shelves[sku] - Catalog::TestSupport.on_hand(sku)
    def held(sku) = Catalog::TestSupport.on_hand(sku) - Catalog::TestSupport.available(sku)

    # A request and everything it caused share one correlation: the request's own.
    def assert_one_flow(publications)
      assert publications.any?, "expected the flow to publish something"
      assert_equal 1, publications.map(&:correlation_id).uniq.size, "every event of one request shares its correlation"
      flow_of(publications)
    end

    def flow_of(publications) = publications.map(&:correlation_id).uniq.sole

    def notified_kinds(order) = Notifications::TestSupport.kinds(order.id)
    def points(order) = Loyalty::TestSupport.points(order.id)

    def retries_by_job(&block)
      retries = Hash.new(0)
      callback = ->(event) { retries[event.payload[:job].class.name] += 1 }
      ActiveSupport::Notifications.subscribed(callback, "enqueue_retry.active_job", &block)
      retries
    end
end
