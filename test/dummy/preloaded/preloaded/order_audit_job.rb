module Preloaded
  class LedgerPosted < EventRail::Event
    event_type "preloaded.ledger_posted"
    version 1
    default_source "event_rail.preloaded"

    attribute :entry_id, :string
  end

  class OrderAuditJob < ActiveJob::Base
    include EventRail::JobContext

    subscribes_to LedgerPosted

    def perform(event)
      event
    end
  end
end
