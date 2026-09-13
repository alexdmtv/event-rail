module Host
  class AuditApplicationStartedJob < ApplicationJob
    def perform(event)
      event
    end
  end
end
