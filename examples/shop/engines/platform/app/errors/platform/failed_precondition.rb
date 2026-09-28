module Platform
  # Error category: the current state does not allow it. Not retried -- in a job it means an outcome went unhandled; HTTP 409. See Platform::ErrorCategory.
  module FailedPrecondition; end
end
