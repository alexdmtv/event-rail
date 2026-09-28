module Payments
  class ApplicationJob < Platform::ApplicationJob
    queue_as :payments

    # A command that gives up -- its retries exhausted, its provider never answering -- gives up
    # the payment's claim with it, or no other command could ever call the provider for this
    # payment again. It lands in the failed jobs, to be replayed once the provider is back.
    after_discard { |job| Payment.find_by(reference: job.arguments.first)&.give_up_claim(job.job_id) }
  end
end
