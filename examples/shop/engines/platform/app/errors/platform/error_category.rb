module Platform
  # Rails' own errors cannot include a category module without patching Rails, so FRAMEWORK
  # lists theirs.
  module ErrorCategory
    ALL = [ InvalidArgument, NotFound, FailedPrecondition, Aborted, Unavailable, ResourceExhausted, Unauthenticated, PermissionDenied ].freeze

    # The shop worked and the answer is no: never retried, never reported as failures.
    EXPECTED = [ InvalidArgument, NotFound, FailedPrecondition, Unauthenticated, PermissionDenied ].freeze

    FRAMEWORK = {
      "ActionController::ParameterMissing" => InvalidArgument,
      "ActiveRecord::RecordNotFound" => NotFound,
      "ActiveRecord::RecordInvalid" => InvalidArgument,
      "ActiveRecord::StaleObjectError" => Aborted,
      "ActiveRecord::Deadlocked" => Aborted,
      "ActiveRecord::LockWaitTimeout" => Aborted,
      "ActiveRecord::ConnectionTimeoutError" => Unavailable
    }.freeze

    # nil for an error with no category: a bug, or a failure nobody has classified yet.
    def self.of(error)
      ALL.find { |category| error.is_a?(category) } ||
        error.class.ancestors.lazy.filter_map { |ancestor| FRAMEWORK[ancestor.name] }.first
    end

    # For handlers that must name classes, such as retry_on and rescue_from.
    def self.framework_errors(category) = FRAMEWORK.filter_map { |name, listed| name.safe_constantize if listed == category }

    def self.expected?(error) = EXPECTED.include?(of(error))
  end
end
