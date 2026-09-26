module Payments
  # Takes the money an authorization holds. Enqueued by Api.capture.
  class CaptureJob < PaymentJob
    private
      def operation_for(payment) = (:capture if payment.capturable?)
      def report(payment) = report_capture(payment)
  end
end
