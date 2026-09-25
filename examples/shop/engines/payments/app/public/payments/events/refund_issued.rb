module Payments
  module Events
    class RefundIssued < EventRail::Event
      event_type "payments.refund_issued"
      version 1
      default_source "shop.payments"
      identity_by :reference

      attribute :reference, :string
      attribute :amount_cents, :integer
      attribute :currency, :string

      validates :reference, presence: true
    end
  end
end
