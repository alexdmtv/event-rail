module Payments
  module Events
    class AuthorizationVoided < EventRail::Event
      event_type "payments.authorization_voided"
      version 1
      default_source "shop.payments"
      identity_by :reference

      attribute :reference, :string

      validates :reference, presence: true
    end
  end
end
