module Orders
  # The card issuer refused the refund. Retrying will not change its mind, and the customer
  # is owed money, so the order is set aside for a person to resolve.
  class FlagRefusedRefundJob < ApplicationJob
    subscribes_to Payments::Events::RefundFailed

    def perform(event)
      order = Order.find_by(reference: event.reference) or return

      order.transition!(from: %w[ awaiting_return cancelled ], to: "needs_attention", attention_reason: "refund refused: #{event.reason}")
    end
  end
end
