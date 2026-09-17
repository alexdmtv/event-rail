# The same trailing path inside an engine, to prove one configured root covers both without
# naming the engine's directory separately.
module Orders
  class EngineExtraSubscriber < ActiveJob::Base
    include EventRail::JobContext

    subscribes_to Orders::OrderPlaced

    def perform(event)
      event
    end
  end
end
