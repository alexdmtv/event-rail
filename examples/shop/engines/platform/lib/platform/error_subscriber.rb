module Platform
  # Turns every error reported to Rails.error, from Rails or the shop, into one structured event.
  # Its expected field tells an outcome the shop answered from a failure someone should look at,
  # so a log platform can count the first and alert on the second. An error tracker would
  # subscribe to Rails.error beside this one, taking only the unexpected.
  class ErrorSubscriber
    # context is Rails.error's, which holds Rails' own controller or job object; the event carries
    # the shop's context (Platform::Observability).
    def report(error, handled:, severity:, context:, source: nil)
      Rails.event.notify("platform.error_reported",
        error_class: error.class.name, message: error.message, category: ErrorCategory.of(error)&.name&.demodulize,
        expected: ErrorCategory.expected?(error), handled:, severity:, source:)
    end
  end
end
