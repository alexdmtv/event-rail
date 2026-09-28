module Payments
  # Returns captured money to the customer. Accepted by Api.request_refund.
  class RefundJob < ApplicationJob
    # A reference with no payment -- its authorization declined, or never reached the provider --
    # has nothing to refund.
    def perform(reference) = Payment.find_by(reference: reference)&.refund(claimant: job_id)
  end
end
