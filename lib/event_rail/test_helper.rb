require "event_rail"

module EventRail
  # Test support, loaded only by an explicit `require "event_rail/test_helper"`. Requiring
  # the library does not load it, and requiring it does not by itself weaken the rule that
  # a declaration arriving after preparation is an error.
  #
  #   # test/test_helper.rb
  #   require "event_rail/test_helper"
  #
  #   class ActiveSupport::TestCase
  #     include EventRail::TestHelper
  #   end
  #
  # Including the module adds `with_subscribers` and nothing else. `declare` stays a module
  # method rather than becoming an instance method on every test case, because the name is
  # general enough to collide.
  module TestHelper
    # Opens a window in which event contracts and subscriptions may be declared even though
    # preparation has already sealed the registry. Fixtures go at file scope, once per
    # process:
    #
    #   EventRail::TestHelper.declare do
    #     module OrderTests
    #       class Placed < EventRail::Event
    #         event_type "tests.order_placed"
    #         version 1
    #         default_source "tests"
    #
    #         attribute :order_id, :string
    #       end
    #
    #       class AuditJob < ApplicationJob
    #         subscribes_to Placed
    #
    #         def perform(event) = (self.class.seen << event)
    #       end
    #     end
    #   end
    #
    # Contracts declared here are indexed when the window closes and stay indexed: a class
    # cannot be unloaded, so two fixtures claiming one event type and version fail every
    # later rebuild, not just the first. Give each fixture a unique type, and declare it at
    # file scope -- a declaration inside a test method reopens the same constant and runs the
    # writer again on a sealed registry.
    #
    # Subscriptions declared here are dormant. They receive nothing until `with_subscribers`
    # activates them, so a fixture cannot fan out in a later test that never mentions it.
    def self.declare(&block)
      # Unqualified, so lexical lookup reaches the private Internal namespace that a
      # qualified EventRail::Internal reference would be refused.
      Internal::Registry.declare_fixtures(&block)
    end

    # Activates fixture subscribers for the duration of the block and restores the previous
    # registry afterwards, including when the block raises. Nested calls are additive.
    #
    #   test "publication fans out to the audit job" do
    #     with_subscribers(OrderTests::AuditJob) do
    #       publication = EventRail.publish(OrderTests::Placed.new(order_id: "o-1"))
    #
    #       assert_enqueued_with job: OrderTests::AuditJob, args: [ publication.event ]
    #     end
    #   end
    #
    # The registry snapshot this replaces is process-wide, so activation is not safe under
    # thread-based test parallelisation (`parallelize(with: :threads)`). Process-based
    # parallelisation, which is the Rails default, is unaffected because each worker has its
    # own registry.
    def with_subscribers(*job_classes, &block)
      Internal::Registry.activate(job_classes.flatten, &block)
    end
  end
end
