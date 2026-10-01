module Platform
  # Each module's own ApplicationController inherits from this one. The shop speaks JSON, and
  # an error with a category is answered with the status that category calls for and the
  # error's message, so no action rescues anything. It is still reported, and the error
  # subscriber counts an expected one and logs the rest. An error with no category -- a bug --
  # is a 500 (see Platform::ErrorCategory).
  class ApplicationController < ActionController::API
    STATUSES = {
      InvalidArgument => :unprocessable_content,
      NotFound => :not_found,
      FailedPrecondition => :conflict,
      Aborted => :conflict,
      Unavailable => :service_unavailable,
      ResourceExhausted => :too_many_requests,
      Unauthenticated => :unauthorized,
      PermissionDenied => :forbidden
    }.freeze

    rescue_from(*ErrorCategory::ALL, *ErrorCategory::ALL.flat_map { |category| ErrorCategory.framework_errors(category) }) do |error|
      Rails.error.report(error, context: { correlation_id: EventRail::Current.correlation_id }.compact)
      render json: { error: error.message }, status: STATUSES.fetch(ErrorCategory.of(error))
    end
  end
end
