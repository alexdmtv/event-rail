module Platform
  # The one place errors are reported from. Rails hands it every error left unhandled by a
  # request, a job or a runner, and every error code reports with Rails.error.report; code
  # itself never logs an error and raises it again.
  #
  # It applies the categories (see Platform::ErrorCategory): an expected failure -- a refusal, a missing
  # record -- is counted, not reported, because the code that raised it meant it. Anything
  # else is reported with the flow it happened in. A job's retryable failure reaches here only
  # once its retries have run out: until then, its retry_on has handled it.
  #
  # The shop reports to its log. A real application adds its error tracker's subscriber, and
  # alerts from the tracker rather than from here.
  class ErrorSubscriber
    def report(error, handled:, severity:, context:, source: nil)
      category = ErrorCategory.of(error)
      if ErrorCategory.expected?(error)
        ActiveSupport::Notifications.instrument("expected_failure.platform", error_class: error.class.name, category: category.name)
      else
        flow = context.slice(:correlation_id, :causation_id).compact.map { |key, value| "#{key}=#{value}" }.join(" ")
        Rails.logger.error("[#{category&.name&.demodulize || "Unclassified"}] #{error.class}: #{error.message} (#{severity}, #{handled ? "handled" : "unhandled"}, #{source}) #{flow}".rstrip)
      end
    end
  end
end
