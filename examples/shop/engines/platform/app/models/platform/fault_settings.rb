module Platform
  # The demonstration's fault knobs, set from the developer console while the shop runs.
  # They live in Platform because the fake payment gateway and the fake carrier read them,
  # and Platform is the one module every module may depend on: the console writes these
  # settings, and no module has to depend on anything above it to read them.
  #
  # This exists for the demonstration only. A real application does not ship switches that
  # make its payment provider fail.
  class FaultSettings < ApplicationRecord
    RATES = %i[ authorization_decline_rate capture_refusal_rate refund_refusal_rate temporary_failure_rate ].freeze

    validates(*RATES, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 })
    validates :carrier_delay_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    def self.current = first_or_create!

    # True with the probability the named rate holds.
    def self.roll?(rate) = rand < current.public_send(rate)

    def self.carrier_delay = current.carrier_delay_seconds.seconds

    # Makes the named job fail its next `count` runs.
    def self.force_failures(job_class, count)
      settings = current
      settings.update!(forced_failures: settings.forced_failures.merge(job_class.to_s => Integer(count)))
    end

    # A cheap read first, so that jobs nobody asked to fail never take a write lock.
    def self.forced_failures_pending?(job_class) = current.forced_failures.fetch(job_class.to_s, 0).positive?

    # Consumes one forced failure for the named job, atomically, and says whether it had one.
    def self.consume_forced_failure(job_class)
      transaction do
        settings = current.lock!
        remaining = settings.forced_failures.fetch(job_class.to_s, 0)
        next false unless remaining.positive?

        settings.update!(forced_failures: settings.forced_failures.merge(job_class.to_s => remaining - 1))
        true
      end
    end
  end
end
