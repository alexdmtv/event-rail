module Orders
  class Order
    # When an order is given up for taking too long. Cancellable carries the cancellation out.
    module Expirable
      extend ActiveSupport::Concern

      CONFIRMATION_DEADLINE = 2.minutes # so the customer hears within minutes, whatever is failing
      PAYMENT_DEADLINE = 30.minutes

      included do
        scope :unconfirmed_past_deadline, -> { where(state: "placed").where(created_at: ...CONFIRMATION_DEADLINE.ago) }
        scope :unpaid_past_deadline, -> { where(state: "confirmed", paid_at: nil).where(confirmed_at: ...PAYMENT_DEADLINE.ago) }
      end

      class_methods do
        def expire_overdue
          request_cancellations(unconfirmed_past_deadline, reason: "not confirmed in time")
          request_cancellations(unpaid_past_deadline, reason: "not paid in time")
        end

        private
          # An order that shipped while the sweep ran is skipped.
          def request_cancellations(orders, reason:)
            orders.find_each do |order|
              order.request_cancellation(reason: reason)
            rescue NotCancellable
              next
            end
          end
      end
    end
  end
end
