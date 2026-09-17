# Outside every default root. Discovered only when DUMMY_EXTRA_ROOT adds app/subscribers to
# config.event_rail.roots, which is what the configurable-roots tests assert.
class HostExtraSubscriber < ApplicationJob
  subscribes_to Host::ApplicationStarted

  def perform(event)
    event
  end
end
