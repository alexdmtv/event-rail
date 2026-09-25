module Payments
  module Events
    class PaymentCaptured < EventRail::Event
      event_type "payments.payment_captured"
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
