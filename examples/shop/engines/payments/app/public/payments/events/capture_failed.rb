module Payments
  module Events
    class CaptureFailed < EventRail::Event
      event_type "payments.capture_failed"
      version 1
      default_source "shop.payments"
      identity_by :reference

      attribute :reference, :string
      attribute :reason, :string

      validates :reference, presence: true
    end
  end
end
