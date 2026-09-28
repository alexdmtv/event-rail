module Payments
  # Takes the money an authorization holds. Accepted by Api.request_capture.
  class CaptureJob < ApplicationJob
    def perform(reference) = Payment.find_by(reference: reference)&.capture(claimant: job_id)
  end
end
