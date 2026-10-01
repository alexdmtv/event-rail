require "test_helper"

# Whole-flow tests drive an order through every module the way the running shop does -- the
# worker performs one job at a time and contains each failure -- and then check what each
# module ended up with, through each module's test support.
class FlowTestCase < ActiveSupport::TestCase
  include ShopHelpers

  setup do
    stock_shelves
    instant_carrier
  end

  private
    # Checks out and works off everything that follows, recording what was published.
    def place_and_settle(**checkout_options)
      order = nil
      publications = record_publications do
        order = checkout(**checkout_options)
        @job_failures = work_off_queue
      end
      [ Orders::TestSupport.order(order.id), publications ]
    end

    def settle
      publications = record_publications { @job_failures = work_off_queue }
      publications
    end

    def assert_one_flow(order, publications)
      assert publications.any?, "expected the flow to publish something"
      assert_equal [ order.correlation_id ], publications.map(&:correlation_id).uniq, "every event of an order shares its correlation"
    end

    def notified_kinds(order) = Notifications::TestSupport.kinds(order.id)
    def points(order) = Loyalty::TestSupport.points(order.id)
    def retries_by_job(&block)
      retries = Hash.new(0)
      callback = ->(event) { retries[event.payload[:job].class.name] += 1 }
      ActiveSupport::Notifications.subscribed(callback, "enqueue_retry.active_job", &block)
      retries
    end
end
