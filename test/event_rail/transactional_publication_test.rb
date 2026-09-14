require "test_helper"
require "active_record"

# The primary dummy application deliberately has no database, so this is the one fixture
# that loads Active Record and opens a real transaction. In-memory SQLite keeps it
# serviceless.
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

Registry.reopen do
  module TransactionFixtures
    class Placed < EventRail::Event
      event_type "tests.transaction_placed"
      version 1
      default_source "acme.orders"

      attribute :order_id, :string
      identity_by :order_id
    end
  end
end

Registry.prepare

class TransactionalPublicationTest < ActiveSupport::TestCase
  Transaction = EventRailInternal::Transaction

  setup { EventRail::Current.reset }
  teardown { EventRail::Current.reset }

  test "publishing inside an open transaction raises and names the fix" do
    error = assert_raises(EventRail::TransactionalPublicationError) do
      ActiveRecord::Base.transaction do
        EventRail.publish(TransactionFixtures::Placed.new(order_id: "o-1"))
      end
    end

    assert_match(/after the transaction commits/, error.message)
    assert_empty enqueued_jobs, "nothing may be enqueued from inside the transaction"
  end

  # Both settings are wrong inside a transaction, in opposite directions: deferred
  # enqueue cannot report its own failure, and immediate enqueue announces a fact a
  # rollback then contradicts. So the check is on the open transaction itself, not on the
  # setting.
  test "the check is independent of the queue deferral setting" do
    [ true, false ].each do |deferral|
      with_deferral(deferral) do
        assert_raises(EventRail::TransactionalPublicationError, "deferral=#{deferral}") do
          ActiveRecord::Base.transaction do
            EventRail.publish(TransactionFixtures::Placed.new(order_id: "o-1"))
          end
        end
      end
    end
  end

  test "a nested transaction is still an open transaction" do
    assert_raises(EventRail::TransactionalPublicationError) do
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.transaction(requires_new: true) do
          EventRail.publish(TransactionFixtures::Placed.new(order_id: "o-1"))
        end
      end
    end
  end

  test "the check is inert when no transaction is open" do
    refute_predicate Transaction, :open?

    publication = EventRail.publish(TransactionFixtures::Placed.new(order_id: "o-1"))

    assert_predicate publication.event, :stamped?
  end

  test "publishing after the transaction commits is the documented fix" do
    event = nil

    ActiveRecord::Base.transaction { nil }
    event = EventRail.publish(TransactionFixtures::Placed.new(order_id: "o-1")).event

    assert_predicate event, :stamped?
  end

  test "the check is inert when Active Record is absent" do
    detached = Module.new
    Object.stub_const(:ActiveRecord, detached) do
      refute_predicate Transaction, :open?
      refute_nil EventRail.publish(TransactionFixtures::Placed.new(order_id: "o-2"))
    end
  end

  private
    # Defined on the adapter instance so it works whether or not this Rails version's
    # test adapter inherits the predicate, and removed again rather than restored.
    def with_deferral(enabled)
      adapter = ActiveJob::Base.queue_adapter
      adapter.define_singleton_method(:enqueue_after_transaction_commit?) { enabled }
      yield
    ensure
      adapter.singleton_class.send(:remove_method, :enqueue_after_transaction_commit?)
    end
end

# Minitest has no constant stubbing, and this is the only place that needs it: removing
# Active Record from a running process is not possible, so the check is exercised against
# a module that does not answer its API.
class Object
  def self.stub_const(name, replacement)
    original = const_get(name)
    send(:remove_const, name)
    const_set(name, replacement)
    yield
  ensure
    send(:remove_const, name)
    const_set(name, original)
  end
end
