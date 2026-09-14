require "active_support/notifications"

module EventRail
  module Internal
    # Payloads for the four public notifications.
    #
    # Contract, identity, and lineage only. Domain data and extensions are excluded by
    # construction rather than by filtering, because a notification payload reaches logs
    # and APM by default and a fact's contents are the application's to decide about.
    # Every call site uses the block form, so Rails' own :exception keys report failures
    # and EventRail needs no separate failure event.
    module Notifications
      module_function

      # The same keys, read from the private queue representation, for the one
      # notification that fires before a typed event exists.
      def payload_for_representation(hash)
        metadata = hash["metadata"] || {}

        {
          event_type: hash["event_type"],
          event_version: hash["event_version"],
          event_id: metadata["id"],
          source: metadata["source"],
          correlation_id: metadata["correlation_id"],
          causation_id: metadata["causation_id"]
        }
      end

      def payload_for(event)
        {
          event_type: event.event_type,
          event_version: event.version,
          event_id: event.id,
          source: event.source,
          correlation_id: event.correlation_id,
          causation_id: event.causation_id
        }
      end
    end
  end
end
