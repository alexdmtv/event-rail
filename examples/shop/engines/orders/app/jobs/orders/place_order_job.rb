module Orders
  # Places an order checkout recorded: reserves its stock and authorizes its card under the
  # order's reference, and records the outcome, placed or rejected. Then, whatever happened
  # before, it makes what the shop holds match that outcome: a placed order is announced and
  # its capture requested; a rejected one gets its stock and its card's hold back.
  #
  # Every step is idempotent on the order's reference, so a retry, a second hand-over by the
  # relay, or a crash at any point runs the job again to the same end. The second half also
  # settles the one race: the expiry rejecting the order while this job is reserving or
  # authorizing. The move to placed then fails, the order is rejected, and the job gives back
  # what it has just taken.
  class PlaceOrderJob < ApplicationJob
    # A payment provider still unavailable after this many attempts rejects the order rather
    # than leaving it pending; the customer can try again.
    AUTHORIZATION_ATTEMPTS = 3

    # Later declarations are consulted first.
    retry_on Payments::Api::Unavailable, wait: 2.seconds, attempts: AUTHORIZATION_ATTEMPTS

    def perform(order_id)
      order = Order.find(order_id)
      place(order) if order.pending?
      settle(order.reload)
    end

    private
      def place(order)
        Catalog::Api.reserve(reservation_id: order.reference, items: order.items)
        Payments::Api.authorize(reference: order.reference, amount_cents: order.total_cents, currency: order.currency)
        order.transition!(from: "pending", to: "placed", placed_at: Time.current)
      rescue Catalog::OutOfStock => out_of_stock
        order.reject!(out_of_stock.message)
      rescue Payments::Api::Declined => declined
        order.reject!("payment declined: #{declined.message}")
      rescue Payments::Api::Unavailable => unavailable
        # Decided here, inside perform, so that the rejection's give-back runs in the order's
        # flow; a retry_on block would run after the job's EventRail context has closed.
        raise if executions < AUTHORIZATION_ATTEMPTS

        order.reject!("payment provider unavailable: #{unavailable.message}")
      end

      def settle(order)
        if order.placed_at? then announce(order)
        elsif order.rejected? then give_back(order)
        end
      end

      # An order that was placed is announced even if it has moved on since: the announcement
      # is unconditional, so a run that crashed after publishing publishes again, under the
      # same identity -- OrderPlaced is identified by its order.
      def announce(order)
        EventRail.publish(Events::OrderPlaced.new(
          **order.event_attributes, total: order.total,
          line_items: order.line_items.map do |line|
            { "sku" => line.sku, "name" => line.name, "quantity" => line.quantity, "unit_price_cents" => line.unit_price_cents }
          end
        ))
        Payments::Api.capture(reference: order.reference) if order.placed?
      end

      # Both are attempted even if one fails, and both are safe to repeat whether or not
      # anything was reserved or authorized; the job's retry finishes what is left.
      def give_back(order)
        failure = nil
        [ -> { Catalog::Api.release(reservation_id: order.reference) }, -> { Payments::Api.void(reference: order.reference) } ].each do |step|
          step.call
        rescue => error
          failure ||= error
        end
        raise failure if failure
      end
  end
end
