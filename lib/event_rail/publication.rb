module EventRail
  # What `EventRail.publish` returns: the stamped fact, plus which subscribers took it
  # and which deliberately declined it.
  #
  # Delivery outcome is not event metadata -- an event is the same fact regardless of
  # who received it -- so it lives here instead. The skipped list is the part that
  # matters operationally: a subscriber's own uniqueness, concurrency, or feature-flag
  # callback aborting its enqueue is a decision, not a fault, and this is where an
  # application can see it happened.
  class Publication
    attr_reader :event, :accepted_subscribers, :skipped_subscribers

    def initialize(event:, accepted_subscribers:, skipped_subscribers:)
      @event = event
      @accepted_subscribers = accepted_subscribers.freeze
      @skipped_subscribers = skipped_subscribers.freeze
      freeze
    end

    def subscriber_count
      accepted_subscribers.length + skipped_subscribers.length
    end

    def id
      event.id
    end

    def inspect
      "#<EventRail::Publication event=#{event.inspect} accepted=#{accepted_subscribers.length} " \
        "skipped=#{skipped_subscribers.length}>"
    end
  end
end
