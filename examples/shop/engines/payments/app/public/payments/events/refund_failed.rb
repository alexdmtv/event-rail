module Payments
  module Events
    class RefundFailed < EventRail::Event
      event_type "payments.refund_failed"
      version 1
      default_source "shop.payments"
      identity_by :reference

      attribute :reference, :string
      attribute :reason, :string

      validates :reference, presence: true
    end
  end
end
