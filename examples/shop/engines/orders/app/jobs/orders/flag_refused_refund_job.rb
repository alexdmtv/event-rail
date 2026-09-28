module Orders
  # The card issuer refused a refund. Retrying will not change its mind, and the customer is
  # owed money, so a person has to resolve it.
  class FlagRefusedRefundJob < ApplicationJob
    subscribes_to Payments::Events::RefundFailed

    def perform(event) = Order.find_by(reference: event.reference)&.flag_refused_refund(event.reason)
  end
end
