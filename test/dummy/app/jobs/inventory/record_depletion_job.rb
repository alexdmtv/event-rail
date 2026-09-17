module Inventory
  class RecordDepletionJob < ApplicationJob
    subscribes_to StockDepleted

    def perform(event)
      event
    end
  end
end
