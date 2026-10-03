module Platform
  # Counts expected failures and logs the rest. A job's retryable failure reaches it only once
  # its retries have run out.
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
