module Platform
  # Each module's own ApplicationController inherits from this one. The shop speaks JSON, and
  # an error with a category is answered with the status that category calls for, so no action
  # rescues anything. It is still reported, and the error subscriber counts an expected one and
  # logs the rest. An error with no category -- a bug -- is left to Platform::ExceptionsApp.
  #
  # Every error is answered as problem details (RFC 9457): a title and status, the error's
  # detail, and a code naming what happened (not_cancellable). Refused input adds errors, one
  # per violation, each with a JSON Pointer into the request (/customer/email), a code and a
  # detail, so a form can show each one beside its field.
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
      render_problem error, status: Rack::Utils.status_code(STATUSES.fetch(ErrorCategory.of(error)))
    end

    private
      def render_problem(error, status:)
        problem = { title: Rack::Utils::HTTP_STATUS_CODES[status], status: status, detail: error.message, code: error.class.name.demodulize.underscore }
        violations = violations_of(error)
        problem[:errors] = violations.map { |violation| { pointer: pointer(violation.field), code: violation.code, detail: violation.message } } if violations.any?
        render json: problem, status: status, content_type: Mime[:problem].to_s
      end

      # Rails' own input errors are given violations too, in the same shape. A record's
      # validation names the record's attributes, not the request's fields: a module checks its
      # input before it builds a record, so this is a backstop.
      def violations_of(error)
        case error
        when InvalidInput then error.violations
        when ActiveRecord::RecordInvalid then InvalidInput.from(error.record.errors).violations
        when ActionController::ParameterMissing then [ InvalidInput::Violation.new(field: error.param.to_s, code: "missing", message: "is missing") ]
        else []
        end
      end

      def pointer(field) = field.split(".").map { |part| "/" + part.gsub("~", "~0").gsub("/", "~1") }.join
  end
end
