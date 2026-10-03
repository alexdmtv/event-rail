module Orders
  class Order
    module Confirmable
      extend ActiveSupport::Concern

      CONFIRMATION_DEADLINE = 2.minutes

      included do
        scope :unconfirmed_past_deadline, -> { where(state: "placed").where(created_at: ...CONFIRMATION_DEADLINE.ago) }
      end

      class_methods do
        def cancel_unconfirmed = request_cancellations(unconfirmed_past_deadline, reason: "not confirmed in time")
      end

      # Safe to repeat: every step is keyed by the order's reference, so a retry, or a crash at
      # any point, runs it again to the same end.
      def confirm
        hold_and_authorize if placed?
        if confirmed?
          Payments::Api.request_capture(reference: reference)
        elsif cancelled?
          # Cancelled while this ran: release what this run took after the cancellation released
          # what it found.
          release_holds
        end
      rescue Catalog::OutOfStock => out_of_stock
        request_cancellation(reason: out_of_stock.message)
      rescue Payments::Declined => declined
        request_cancellation(reason: "payment declined: #{declined.message}")
      end

      private
        def hold_and_authorize
          Catalog::Api.reserve(reservation_id: reference, items: items)
          Payments::Api.authorize(reference: reference, amount_cents: total_cents, currency: currency)
          update_if({ state: "placed" }, state: "confirmed", confirmed_at: Time.current)
        end
    end
  end
end
