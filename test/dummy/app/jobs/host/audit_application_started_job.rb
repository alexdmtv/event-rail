module Host
  class AuditApplicationStartedJob < ApplicationJob
    subscribes_to Host::ApplicationStarted

    def perform(event)
      event
    end
  end
end
