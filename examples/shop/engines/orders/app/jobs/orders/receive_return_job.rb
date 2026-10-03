module Orders
  class ReceiveReturnJob < ApplicationJob
    subscribes_to Fulfillment::Events::ReturnReceived

    def perform(event) = Return.for_reference(event.reference)&.receive
  end
end
