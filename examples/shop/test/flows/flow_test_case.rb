require "test_helper"

class FlowTestCase < ActiveSupport::TestCase
  setup { instant_carrier }

  private
    def place_and_settle(**checkout_options)
      order = nil
      publications = record_publications do
        order = checkout(**checkout_options)
        @job_failures = work_off_queue
      end
      [ Orders::TestSupport.order(order.id), publications ]
    end

    def checkout(**) = Orders::TestSupport.checkout(**)
    def place(**) = Orders::TestSupport.place_and_confirm(**)
    def available(sku) = Catalog::TestSupport.available(sku)
    def on_hand(sku) = Catalog::TestSupport.on_hand(sku)
    def instant_carrier = Fulfillment::TestSupport.instant_carrier
    def slow_carrier = Fulfillment::TestSupport.slow_carrier

    def settle
      publications = record_publications { @job_failures = work_off_queue }
      publications
    end

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
