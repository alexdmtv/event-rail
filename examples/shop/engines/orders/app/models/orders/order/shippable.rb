module Orders
  class Order
    module Shippable
      # Only a paid order is shipped. Safe to repeat: Fulfillment ships once per reference.
      def request_shipment
        return unless confirmed? && paid_at?

        Fulfillment::Api.request_shipment(
          reference: reference,
          recipient: Fulfillment::Api::Recipient.new(name: customer_name, address: shipping_address),
          items: quantities_by_sku
        )
      end

      # Ships the stock on every run, not only the one that records the fact, so a retry after
      # the change committed still ships it.
      def mark_shipped(tracking_code:)
        update_if({ shipped_at: nil }, shipped_at: Time.current, tracking_code: tracking_code) do
          EventRail.stage(Events::OrderShipped.new(**event_attributes, tracking_code: self.tracking_code))
        end
        Catalog::Api.ship(reservation_id: reference)
      end

      # Raises, rather than returns, before the dispatch is recorded: events arrive in any order,
      # and the retry keeps the delivery from being lost.
      def mark_delivered
        raise NotYetShipped, "order #{id} was delivered before its dispatch was recorded" unless shipped_at?

        update_if({ delivered_at: nil }, delivered_at: Time.current) do
          EventRail.stage(Events::OrderDelivered.new(**event_attributes, total: event_total))
        end
      end
    end
  end
end
