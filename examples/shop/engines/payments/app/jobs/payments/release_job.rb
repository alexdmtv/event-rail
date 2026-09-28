module Payments
  # Gives back whatever the payment holds, decided when it runs. Accepted by Api.request_release.
  class ReleaseJob < ApplicationJob
    def perform(reference) = Payment.find_by(reference: reference)&.release(claimant: job_id)
  end
end
