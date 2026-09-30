# The dummy application's stager. It keeps what it is handed instead of persisting it, which
# is all an application without a database can do, so the README's `EventRail.stage` examples
# run, and a boot or a reload resolves a stager configured by name the way an application's
# does.
class RecordingStager
  class << self
    def staged
      @staged ||= []
    end

    def stage(jobs)
      staged.concat(jobs)
    end

    def reset!
      @staged = []
    end
  end
end
