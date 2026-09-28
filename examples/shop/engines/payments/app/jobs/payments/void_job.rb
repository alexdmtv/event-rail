module Payments
  # Releases an authorization that will never be captured -- one never captured, or one whose
  # capture was refused. A payment already captured is not voided; ReleaseJob refunds it
  # instead. Accepted by Api.request_void.
  class VoidJob < ApplicationJob
    def perform(reference) = Payment.find_by(reference: reference)&.void(claimant: job_id)
  end
end
