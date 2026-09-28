module Payments
  # Returns captured money to the customer. Accepted by Api.request_refund.
  class RefundJob < ApplicationJob
    def perform(reference) = Payment.find_by(reference: reference)&.refund(claimant: job_id)
  end
end
