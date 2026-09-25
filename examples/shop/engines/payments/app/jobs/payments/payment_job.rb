module Payments
  # What capture, void and refund share. Each performs one provider call when the payment is
  # still in the state the call needs, and then reports the payment's resulting state as an
  # event -- whether or not this run made the change. Reporting unconditionally is what makes
  # the command safe to repeat: if a previous run crashed after moving the payment but before
  # publishing, this run publishes, under the same identity.
  class PaymentJob < ApplicationJob
    queue_as :payments

    # A provider that keeps timing out is, eventually, a refusal: the caller learns about it
    # through the failure event rather than waiting forever.
    retry_on Gateway::TemporaryFailure, wait: 2.seconds, attempts: 5 do |job, error|
      job.send(:give_up, error)
    end

    def perform(reference)
      payment = Payment.find_by!(reference: reference)
      attempt(payment)
      report(payment)
    end

    private
      def gateway = Gateway.current

      def publish(event) = EventRail.publish(event)
  end
end
