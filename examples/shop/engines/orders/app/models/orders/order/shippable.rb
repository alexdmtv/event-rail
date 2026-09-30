module Orders
  class Order
    # The parcel's journey, as Fulfillment reports it. Each fact is recorded once, with its
    # event staged in the same transaction. The stock is shipped whenever the fact is recorded,
    # not only when this run recorded it: a run retried after its change committed still ships
    # it.
    module Shippable
      # The carrier has the parcel: the reserved stock has physically left the warehouse.
      def mark_shipped(tracking_code:)
        update_if({ shipped_at: nil }, shipped_at: Time.current, tracking_code: tracking_code) do
          EventRail.stage(Events::OrderShipped.new(**event_attributes, tracking_code: self.tracking_code))
        end
        Catalog::Api.ship(reservation_id: reference)
      end

      # The customer has the parcel. A delivery heard before its dispatch is retried until the
      # dispatch is recorded, rather than lost: EventRail promises no order between events.
      def mark_delivered
        raise NotYetShipped, "order #{id} was delivered before its dispatch was recorded" unless shipped_at?

        update_if({ delivered_at: nil }, delivered_at: Time.current) do
          EventRail.stage(Events::OrderDelivered.new(**event_attributes, total: event_total))
        end
      end
    end
  end
end
