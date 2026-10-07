module Platform
  # Turns every error reported to Rails.error, from Rails or the shop, into one structured event.
  # Its expected field tells an outcome the shop answered from a failure someone should look at,
  # so a log platform can count the first and alert on the second. An error tracker would
  # subscribe to Rails.error beside this one, taking only the unexpected.
  class ErrorSubscriber
    # context is Rails.error's: the shop's context (Platform::Observability), which the event
    # carries already, merged with Rails' controller or job object. Of the rest, only what the
    # report passes as context: { details: { ... } } is written, so nothing reaches the log by
    # accident.
    def report(error, handled:, severity:, context:, source: nil)
      reporting do
        payload = { error_class: error.class.name, message: error.message, category: ErrorCategory.of(error)&.name&.demodulize,
                    expected: expected?(error, handled:), handled:, severity:, source: }
        payload[:details] = context[:details] if context[:details]
        Rails.event.notify("platform.error_reported", payload)
      end
    end

    private
      # Expected means answered: a request turned it into a 4xx, or the code that rescued it chose
      # the outcome. The same NotFound escaping a job is a failure.
      def expected?(error, handled:) = handled && ErrorCategory.expected?(error)

      # When writing the event fails, Rails reports that failure, which would come back here and
      # fail the same way until the stack ran out. The error tracker still receives it.
      def reporting
        return if ActiveSupport::IsolatedExecutionState[:platform_reporting_error]

        begin
          ActiveSupport::IsolatedExecutionState[:platform_reporting_error] = true
          yield
        ensure
          ActiveSupport::IsolatedExecutionState[:platform_reporting_error] = false
        end
      end
  end
end
