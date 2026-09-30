module Orders
  class Order
    # Confirming a placed order: its stock held and its card authorized, in a job staged when it
    # was placed. Every step is safe to repeat on the order's reference, so a retry, or a crash
    # at any point, runs it again to the same end.
    module Confirmable
      extend ActiveSupport::Concern

      # A placed order not confirmed by then is cancelled (see DeadlineSweepJob), so the
      # customer hears within minutes, whatever is failing.
      CONFIRMATION_DEADLINE = 2.minutes

      included do
        scope :unconfirmed_past_deadline, -> { where(state: "placed").where(created_at: ...CONFIRMATION_DEADLINE.ago) }
      end

      def confirm_later = ConfirmJob.stage(self)

      def confirm
        announce_placement
        hold_and_authorize if placed?
        if confirmed?
          Payments::Api.request_capture(reference: reference)
        elsif cancelled?
          # Cancelled while this ran: give back whatever this run may have taken after the
          # cancellation gave back what it found.
          release_holds
        end
      rescue Catalog::OutOfStock => out_of_stock
        request_cancellation(reason: out_of_stock.message)
      rescue Payments::Declined => declined
        request_cancellation(reason: "payment declined: #{declined.message}")
      end

      private
        # Every run announces the order, placed however long ago: the announcement carries the
        # same identity each time (OrderPlaced is identified by its order).
        def announce_placement
          EventRail.publish(Events::OrderPlaced.new(
            **event_attributes, total: event_total,
            line_items: line_items.map do |line|
              { "sku" => line.sku, "name" => line.name, "quantity" => line.quantity, "unit_price_cents" => line.unit_price_cents }
            end
          ))
        end

        def hold_and_authorize
          Catalog::Api.reserve(reservation_id: reference, items: items)
          Payments::Api.authorize(reference: reference, amount_cents: total_cents, currency: currency)
          update_if({ state: "placed" }, state: "confirmed", confirmed_at: Time.current)
        end
    end
  end
end
