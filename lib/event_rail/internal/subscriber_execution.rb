require "active_support/concern"

module EventRail
  module Internal
    # Mixed into a job the first time it declares a subscription.
    #
    # A subscriber's logical message is the event it is handling, not the job that
    # delivers it. That matters twice: lineage, so a follow-up event records the
    # delivered event as its cause, and identity, so the follow-up derives the same ID on
    # every delivery of that cause rather than a new one per delivery job.
    module SubscriberExecution
      extend ActiveSupport::Concern

      included do
        # Registered after JobContext's, so it runs inside the installed context and the
        # notification carries the lineage the subscriber actually ran with.
        around_perform do |job, block|
          ActiveSupport::Notifications.instrument(
            "perform_subscriber.event_rail",
            Notifications.payload_for(job.arguments.first).merge(job_class: job.class.name)
          ) { block.call }
        end
      end

      private
        def __event_rail_delivered_event__
          expected = self.class.event_rail_subscriptions
          candidate = arguments.first

          unless arguments.length == 1 && expected.any? { |event_class| candidate.instance_of?(event_class) }
            raise UnexpectedEventError.new(
              "#{self.class} handles #{expected.map(&:to_s).sort.join(", ")} but received #{describe_arguments}",
              job_class: self.class,
              expected_event_classes: expected,
              received_class: candidate.class
            )
          end

          # A proposal has no identity, so there would be nothing to install as the
          # logical message or to scope identity on. Rejecting only by class would let one
          # through, because a proposal is an instance of the declared class.
          unless candidate.stamped?
            raise UnexpectedEventError.new(
              "#{self.class} received an unpublished #{candidate.class} proposal, which carries no event identity",
              job_class: self.class,
              expected_event_classes: expected,
              received_class: candidate.class
            )
          end

          candidate
        end

        def describe_arguments
          return "no arguments" if arguments.empty?

          arguments.map { |argument| argument.class.to_s }.join(", ")
        end
    end
  end
end
