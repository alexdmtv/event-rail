# A concrete event outside every discovery root. It is registered anyway, because the
# subscriber in app/jobs names it and so autoloads it while preparation is still building.
# That is the inconsistency decision 2 preserves deliberately: the same file would be
# rejected if nothing referenced it.
module Inventory
  class StockDepleted < EventRail::Event
    event_type "inventory.stock_depleted"
    version 1
    default_source "event_rail.dummy"

    attribute :sku, :string
  end
end
