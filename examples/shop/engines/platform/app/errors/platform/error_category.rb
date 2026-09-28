module Platform
  # What a caller should do about an error, named after gRPC's status codes. A module's own
  # error names what happened (Orders::NotCancellable) and includes one category module
  # (Platform::FailedPrecondition); only infrastructure reads the category: the base job's
  # retry policy, and the error subscriber.
  #
  # Errors raised by Rails itself cannot include a module without patching Rails, so they are
  # listed here instead.
  module ErrorCategory
    ALL = [ InvalidArgument, NotFound, FailedPrecondition, Aborted, Unavailable, ResourceExhausted, Unauthenticated, PermissionDenied ].freeze

    # Expected failures: the shop worked and the answer is no -- bad input, a refusal, nothing
    # found. A caller handles them; they are never retried and never reported as failures.
    EXPECTED = [ InvalidArgument, NotFound, FailedPrecondition, Unauthenticated, PermissionDenied ].freeze

    FRAMEWORK = {
      "ActiveRecord::RecordNotFound" => NotFound,
      "ActiveRecord::RecordInvalid" => InvalidArgument,
      "ActiveRecord::StaleObjectError" => Aborted,
      "ActiveRecord::Deadlocked" => Aborted,
      "ActiveRecord::LockWaitTimeout" => Aborted,
      "ActiveRecord::ConnectionTimeoutError" => Unavailable
    }.freeze

    # The category of an error, or nil when it has none: a bug, or a failure nobody has
    # classified yet.
    def self.of(error)
      ALL.find { |category| error.is_a?(category) } ||
        error.class.ancestors.lazy.filter_map { |ancestor| FRAMEWORK[ancestor.name] }.first
    end

    # The framework error classes of a category, for handlers that must name classes.
    def self.framework_errors(category) = FRAMEWORK.filter_map { |name, listed| name.safe_constantize if listed == category }

    def self.expected?(error) = EXPECTED.include?(of(error))
  end
end
