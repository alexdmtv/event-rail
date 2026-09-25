module Observability
  # Keeps the flow records to the newest 20,000 of each kind. A scheduled chore outside every
  # flow, so it carries no EventRail context.
  class PruneJob < ActiveJob::Base
    KEEP = 20_000

    def perform(keep: KEEP)
      [ Node, Attempt ].each do |model|
        threshold = model.order(id: :desc).offset(keep).pick(:id) or next
        model.where(id: ..threshold).delete_all
      end
    end
  end
end
