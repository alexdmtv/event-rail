module Payments
  class Payment
    # One logical call to the provider for a payment: a capture, a void or a refund, sent once or
    # again under the same idempotency key. It is outstanding while pending or sent, and closes
    # once, answered or superseded. Only its payment changes it.
    class ProviderCall < ApplicationRecord
      self.table_name = "payments_provider_calls"

      belongs_to :payment

      attr_readonly :payment_id, :kind, :idempotency_key

      # Their bang methods (refused!) skip the call's transitions; never call them.
      enum :kind, %w[ capture void refund ].index_by(&:itself), validate: true
      enum :state, %w[ pending sent succeeded refused superseded ].index_by(&:itself), validate: true

      scope :outstanding, -> { where(state: %w[ pending sent ]) }

      # Sending again keeps the first time it was sent.
      def mark_sent = update!(state: "sent", sent_at: sent_at || Time.current)
      def supersede = update!(state: "superseded")
      def answer(refusal) = update!(state: refusal ? "refused" : "succeeded", failure_reason: refusal, answered_at: Time.current)

      # Asks the provider; nil when it agreed, the reason when it refused. A temporary failure
      # raises, and the call stays sent.
      def send_to_provider
        case kind
        when "capture" then gateway.capture(idempotency_key:, authorization_code: payment.authorization_code, amount_cents: payment.amount_cents)
        when "void" then gateway.void(idempotency_key:, authorization_code: payment.authorization_code)
        when "refund" then gateway.refund(idempotency_key:, authorization_code: payment.authorization_code, amount_cents: payment.amount_cents)
        end
        nil
      rescue Gateway::Refused => refusal
        refusal.message
      end

      private
        def gateway = Gateway.current
    end
  end
end
