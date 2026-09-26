module Fulfillment
  class ApplicationJob < Platform::ApplicationJob
    queue_as :fulfillment

    # The carrier's steps are what move a shipment on; a failed step is tried again rather
    # than leaving the parcel where it is.
    retry_on StandardError, wait: 2.seconds, attempts: 10
  end
end
