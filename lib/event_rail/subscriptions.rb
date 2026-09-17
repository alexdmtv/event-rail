module EventRail
  # The class macro that declares a subscription. Extended onto `ActiveJob::Base`, so
  # it is available on any ordinary job:
  #
  #   class Billing::OnOrderPlacedJob < ApplicationJob
  #     subscribes_to Orders::OrderPlaced
  #
  #     def perform(event)
  #       Billing.charge(order_id: event.order_id, idempotency_key: event.id)
  #     end
  #   end
  #
  # Only class methods are added, and nothing about serialization or execution
  # changes for a job that never calls the macro. It is available on every job rather
  # than only on jobs that include `EventRail::JobContext` so that a subscriber
  # missing that inclusion fails application preparation with a precise message
  # instead of a bare NoMethodError on the macro.
  module Subscriptions
    # Declares the exact event classes this job handles. The relationship is recorded
    # for preparation to validate: `perform` is usually defined after this line, and
    # whether this class has subclasses is not knowable until everything is loaded, so
    # only what can be judged immediately is judged here.
    def subscribes_to(*event_classes)
      if event_classes.empty?
        raise DeclarationError, "#{self} must name at least one event class to subscribe to"
      end

      own = (@event_rail_subscriptions ||= [])

      event_classes.each do |event_class|
        unless event_class.is_a?(Class) && event_class < EventRail::Event
          raise DeclarationError,
            "#{self} cannot subscribe to #{event_class.inspect}, which is not an EventRail::Event class"
        end
        if own.include?(event_class)
          raise DeclarationError, "#{self} already declares a subscription to #{event_class}"
        end

        own << event_class
      end

      # Checked here rather than during preparation, and after the arguments above rather
      # than before them. Active Job cannot enqueue a job it cannot name, so an anonymous
      # subscriber is never a working configuration -- but preparation is the wrong place to
      # say so: the macro has already recorded the class by then, and rejecting it there
      # would make every later rebuild in the process fail, including in unrelated tests.
      # After the argument checks, because a bad argument on an anonymous class deserves the
      # specific error rather than this one.
      if name.nil?
        raise DeclarationError,
          "#{inspect} declared a subscription but has no name, and Active Job cannot enqueue a job it cannot " \
          "name; assign the class to a constant"
      end

      Internal::Registry.declare(self, caller_locations(1, 1).first)
      include Internal::SubscriberExecution unless include?(Internal::SubscriberExecution)

      event_rail_subscriptions
    end

    # This class's own declarations. Deliberately not inherited: a subclass of a
    # subscriber is a different job, and silently registering it as a second
    # subscriber would double every delivery.
    def event_rail_subscriptions
      (@event_rail_subscriptions || []).dup.freeze
    end

    def event_rail_subscriber?
      !(@event_rail_subscriptions || []).empty?
    end
  end
end
