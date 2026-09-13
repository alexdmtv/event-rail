module Host
  class ApplicationStarted < EventRail::Event
    event_type "host.application_started"
    version 1
    default_source "event_rail.host"

    attribute :boot_id, :string
  end
end
