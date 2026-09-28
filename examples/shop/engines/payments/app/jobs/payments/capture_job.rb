module Payments
  # Takes the money an authorization holds. Accepted by Api.request_capture.
  class CaptureJob < ApplicationJob
    # A reference with no payment -- its authorization declined, or never reached the provider --
    # has nothing to capture.
    def perform(reference) = Payment.find_by(reference: reference)&.capture(claimant: job_id)
  end
end
