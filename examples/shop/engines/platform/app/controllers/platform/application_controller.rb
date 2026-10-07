module Platform
  # Answers a categorised error as problem details (RFC 9457); an uncategorised one, a bug, is
  # left to Platform::ExceptionsApp.
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

    # Each request is a flow of its own: its ID is the correlation of every job and event it causes.
    around_action { |_, action| EventRail.with_context(message_id: request.request_id) { action.call } }
    before_action { Observability.set_context(request_id: request.request_id, message_id: EventRail::Current.message_id, correlation_id: EventRail::Current.correlation_id) }

    rescue_from(*ErrorCategory::ALL, *ErrorCategory::ALL.flat_map { |category| ErrorCategory.framework_errors(category) }) do |error|
      Rails.error.report(error)
      render_problem error, status: Rack::Utils.status_code(STATUSES.fetch(ErrorCategory.of(error)))
    end

    private
      def render_problem(error, status:)
        problem = { title: Rack::Utils::HTTP_STATUS_CODES[status], status: status, detail: error.message, code: error.class.name.demodulize.underscore }
        violations = violations_of(error)
        problem[:errors] = violations.map { |violation| { pointer: pointer(violation.field), code: violation.code, detail: violation.message } } if violations.any?
        render json: problem, status: status, content_type: Mime[:problem].to_s
      end

      # RecordInvalid is a backstop for one a module did not turn into InvalidInput: its
      # attributes need not be the request's fields.
      def violations_of(error)
        case error
        when InvalidInput then error.violations
        when ActiveRecord::RecordInvalid then InvalidInput.from(error.record.errors).violations
        when ActionController::ParameterMissing then [ InvalidInput::Violation.new(field: error.param.to_s, code: "missing", message: "is missing") ]
        else []
        end
      end

      # items[1].quantity -> /items/1/quantity
      def pointer(field) = field.scan(/[^.\[\]]+/).map { |part| "/" + part.gsub("~", "~0").gsub("/", "~1") }.join
  end
end
