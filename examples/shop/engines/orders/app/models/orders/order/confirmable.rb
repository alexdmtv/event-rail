module Orders
  class Order
    module Confirmable
      # Safe to repeat: every step is keyed by the order's reference, so a retry, or a crash at
      # any point, runs it again to the same end.
      def confirm
        hold_and_authorize if placed?
        request_payment
        # Cancelled while this ran: release what this run took after the cancellation released
        # what it found.
        release_holds if cancelled?
      rescue Catalog::OutOfStock => out_of_stock
        request_cancellation(reason: out_of_stock.message)
      rescue Payments::Declined => declined
        request_cancellation(reason: "payment declined: #{declined.message}")
      end

      private
        def hold_and_authorize
          Catalog::Api.reserve(reservation_id: reference, items: quantities_by_sku)
          Payments::Api.authorize(reference: reference, amount_cents: total_cents, currency: currency)
          update_if({ state: "placed" }, state: "confirmed", confirmed_at: Time.current)
        end
    end
  end
end
