module EventRail
  # What `EventRail.stage` returns: the stamped fact, and the subscriber jobs handed to the
  # stager in place of being enqueued.
  #
  # Not a `Publication`. Accepted and skipped are outcomes of an enqueue, and staging performs
  # none: whether each job reaches the queue, and whether a subscriber's own enqueue callback
  # declines it, is decided later, when the stager hands it over. The jobs are here so a
  # caller can match their IDs with what its stager wrote.
  class StagedPublication
    attr_reader :event, :staged_jobs

    def initialize(event:, staged_jobs:)
      @event = event
      @staged_jobs = staged_jobs.dup.freeze
      freeze
    end

    def staged_subscribers
      staged_jobs.map(&:class)
    end

    def subscriber_count
      staged_jobs.length
    end

    def id
      event.id
    end

    def inspect
      "#<EventRail::StagedPublication event=#{event.inspect} staged=#{subscriber_count}>"
    end
  end
end
